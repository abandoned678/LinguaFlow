#include "RimeBridge.h"

#include <rime_api.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

struct LFRimeSession {
    RimeSessionId identifier;
};

static RimeApi *g_api = NULL;
static int g_initialized = 0;
static char g_last_error[256] = {0};

static void set_error(const char *message) {
    snprintf(g_last_error, sizeof(g_last_error), "%s", message ? message : "Unknown Rime error");
}

static char *copy_string(const char *value) {
    if (!value || !value[0]) {
        return NULL;
    }
    size_t length = strlen(value);
    char *copy = malloc(length + 1);
    if (!copy) {
        set_error("Unable to allocate a Rime string");
        return NULL;
    }
    memcpy(copy, value, length + 1);
    return copy;
}

static double monotonic_ms(void) {
    struct timespec now = {0};
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (double)now.tv_sec * 1000 + now.tv_nsec / 1000000.0;
}

int lf_rime_initialize(
    const char *shared_data_dir,
    const char *user_data_dir,
    const char *log_dir,
    LFRimeStartup *timings
) {
    if (timings) {
        *timings = (LFRimeStartup){0};
    }
    if (g_initialized) {
        return 1;
    }
    if (!shared_data_dir || !user_data_dir) {
        set_error("Rime data directories are required");
        return 0;
    }

    g_api = rime_get_api();
    if (!g_api) {
        set_error("Unable to load the librime API");
        return 0;
    }

    RimeTraits traits = {0};
    RIME_STRUCT_INIT(RimeTraits, traits);
    traits.shared_data_dir = shared_data_dir;
    traits.user_data_dir = user_data_dir;
    traits.distribution_name = "SentenceAlong";
    traits.distribution_code_name = "linguaflow";
    traits.distribution_version = "0.2.2";
    traits.app_name = "rime.linguaflow";
    traits.min_log_level = 2;
    traits.log_dir = log_dir ? log_dir : "";

    double started = monotonic_ms();
    g_api->setup(&traits);
    g_api->initialize(&traits);
    double initialized = monotonic_ms();
    if (g_api->start_maintenance(True)) {
        g_api->join_maintenance_thread();
    }
    if (timings) {
        timings->initialization_ms = initialized - started;
        timings->maintenance_ms = monotonic_ms() - initialized;
    }

    g_initialized = 1;
    g_last_error[0] = '\0';
    return 1;
}

void lf_rime_finalize(void) {
    if (!g_initialized || !g_api) {
        return;
    }
    g_api->cleanup_all_sessions();
    g_api->finalize();
    g_api = NULL;
    g_initialized = 0;
}

const char *lf_rime_last_error(void) {
    return g_last_error;
}

LFRimeSession *lf_rime_session_create(void) {
    if (!g_initialized || !g_api) {
        set_error("Rime is not initialized");
        return NULL;
    }

    RimeSessionId identifier = g_api->create_session();
    if (!identifier) {
        set_error("Unable to create a Rime session");
        return NULL;
    }

    LFRimeSession *session = calloc(1, sizeof(LFRimeSession));
    if (!session) {
        g_api->destroy_session(identifier);
        set_error("Unable to allocate a Rime session");
        return NULL;
    }
    session->identifier = identifier;
    return session;
}

void lf_rime_session_destroy(LFRimeSession *session) {
    if (!session) {
        return;
    }
    if (g_api && session->identifier) {
        g_api->destroy_session(session->identifier);
    }
    free(session);
}

int lf_rime_session_select_schema(LFRimeSession *session, const char *schema_id) {
    if (!session || !g_api || !schema_id) {
        return 0;
    }
    // select_schema can accept the identifier even when its configuration is absent.
    RimeConfig config = {0};
    if (!g_api->schema_open(schema_id, &config)) {
        return 0;
    }
    char loaded_schema[256] = {0};
    int matches = g_api->config_get_string(&config, "schema/schema_id", loaded_schema, sizeof(loaded_schema))
        && strcmp(loaded_schema, schema_id) == 0;
    g_api->config_close(&config);
    return matches ? g_api->select_schema(session->identifier, schema_id) : 0;
}

int lf_rime_session_process_key(LFRimeSession *session, int keycode, int modifiers) {
    return session && g_api
        ? g_api->process_key(session->identifier, keycode, modifiers)
        : 0;
}

int lf_rime_session_commit_composition(LFRimeSession *session) {
    return session && g_api
        ? g_api->commit_composition(session->identifier)
        : 0;
}

void lf_rime_session_set_ascii_punctuation(LFRimeSession *session, int enabled) {
    if (session && g_api) g_api->set_option(session->identifier, "ascii_punct", enabled != 0);
}

void lf_rime_session_clear(LFRimeSession *session) {
    if (session && g_api) {
        g_api->clear_composition(session->identifier);
    }
}

char *lf_rime_session_take_commit(LFRimeSession *session) {
    if (!session || !g_api) {
        return NULL;
    }

    RimeCommit commit = {0};
    RIME_STRUCT_INIT(RimeCommit, commit);
    if (!g_api->get_commit(session->identifier, &commit)) {
        return NULL;
    }
    char *text = copy_string(commit.text);
    g_api->free_commit(&commit);
    return text;
}

void lf_rime_snapshot_free(LFRimeSnapshot *snapshot) {
    if (!snapshot) {
        return;
    }
    free(snapshot->preedit);
    for (int index = 0; index < snapshot->count; ++index) {
        free(snapshot->candidates[index].text);
        free(snapshot->candidates[index].comment);
    }
    free(snapshot->candidates);
    *snapshot = (LFRimeSnapshot){0};
}

static int copy_candidate(LFRimeCandidate *copy, const RimeCandidate *candidate) {
    copy->text = copy_string(candidate->text);
    copy->comment = copy_string(candidate->comment);
    return (!candidate->text || !candidate->text[0] || copy->text) &&
           (!candidate->comment || !candidate->comment[0] || copy->comment);
}

// The API exposes the current schema page and an iterator over all candidates.
// Use the native page directly when possible, otherwise project the same list
// into a session-local page without redeploying shared schema or dictionary data.
static int copy_menu(RimeSessionId id, const RimeMenu *menu, int size, LFRimeSnapshot *snapshot) {
    if (menu->num_candidates <= 0) {
        snapshot->is_last_page = 1;
        return 1;
    }
    if (size < 5 || size > 10 || menu->page_size <= 0) return 0;
    snapshot->candidates = calloc((size_t)size, sizeof(LFRimeCandidate));
    if (!snapshot->candidates) return 0;
    int selected = menu->page_no * menu->page_size + menu->highlighted_candidate_index;
    snapshot->page_number = selected / size;
    snapshot->highlighted_index = selected % size;
    if (size == menu->page_size) {
        snapshot->is_last_page = menu->is_last_page;
        for (int i = 0; i < menu->num_candidates && i < size; ++i) {
            snapshot->count++;
            if (!copy_candidate(&snapshot->candidates[i], &menu->candidates[i])) return 0;
        }
        return 1;
    }
    RimeCandidateListIterator iterator = {0};
    if (!g_api->candidate_list_from_index(id, &iterator, snapshot->page_number * size)) return 0;
    int success = 1;
    while (snapshot->count < size && g_api->candidate_list_next(&iterator)) {
        LFRimeCandidate *item = &snapshot->candidates[snapshot->count++];
        if (!copy_candidate(item, &iterator.candidate)) {
            success = 0;
            break;
        }
    }
    snapshot->is_last_page = snapshot->count < size || !g_api->candidate_list_next(&iterator);
    g_api->candidate_list_end(&iterator);
    return success;
}

int lf_rime_session_copy_snapshot(LFRimeSession *session, int page_size, LFRimeSnapshot *snapshot) {
    if (!snapshot) {
        return 0;
    }
    *snapshot = (LFRimeSnapshot){0};
    if (!session || !g_api) {
        return 0;
    }

    RimeContext context = {0};
    RIME_STRUCT_INIT(RimeContext, context);
    if (!g_api->get_context(session->identifier, &context)) {
        return 0;
    }

    int success = 0;
    const char *preedit = context.composition.preedit;
    snapshot->cursor_byte_offset = context.composition.cursor_pos;
    snapshot->preedit = copy_string(preedit);
    if (preedit && preedit[0] && !snapshot->preedit) {
        goto end;
    }

    success = copy_menu(session->identifier, &context.menu, page_size, snapshot);

end:
    g_api->free_context(&context);
    if (!success) {
        lf_rime_snapshot_free(snapshot);
    }
    return success;
}

int lf_rime_session_select_candidate(LFRimeSession *session, int index) {
    return session && g_api && index >= 0
        ? g_api->select_candidate(session->identifier, (size_t)index)
        : 0;
}

int lf_rime_session_highlight_candidate(LFRimeSession *session, int index) {
    return session && g_api && index >= 0 && RIME_API_AVAILABLE(g_api, highlight_candidate)
        ? g_api->highlight_candidate(session->identifier, (size_t)index)
        : 0;
}

char *lf_rime_session_take_raw_input(LFRimeSession *session) {
    if (!session || !g_api) return NULL;
    char *raw = copy_string(g_api->get_input(session->identifier));
    if (raw) g_api->clear_composition(session->identifier);
    return raw;
}

void lf_rime_string_free(char *value) {
    free(value);
}
