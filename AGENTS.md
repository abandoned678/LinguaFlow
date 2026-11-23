# Agent rules

These rules apply to the whole repository.

## Product boundaries

- This project is a macOS-first input method. Do not add Windows TSF code.
- The typing path must remain local and must never wait for translation.
- Translation is a sidecar preview. It may change host text only after an explicit user shortcut.
- Track only text committed by this input method in the current input session. Do not scan arbitrary host-document history.
- Clear sentence context and cancel translation on deactivation, app/focus changes, navigation, or secure input.
- Do not persist raw sentences or translations without an explicit product decision and user-facing control.

## Lifecycle invariants

- The app owns the global librime runtime; each `IMKInputController` owns one librime session.
- Never consume Command-key shortcuts intended for the host application.
- A stale translation revision must never update the panel or insert text.
- `deactivateServer` must leave no marked text or visible panel behind.
- Keep all librime-owned allocation/free pairs inside the C bridge.
- The Apple Translation provider must remain on-device by default. Any future cloud provider is opt-in and must be visibly identified.

## Development

- Add a failing focused test/check before changing state-machine behavior.
- Run both `input-core-checks` and `rime-checks` after input changes.
- Build both `InputMethod` and `TranslationSetup` after UI or translation changes.
- Do not copy GPL frontend code from Squirrel or MetasequoiaIME. Architectural study is allowed; implementation must remain original.
- Preserve upstream license files and notices for all vendored/submodule data.

## Coordinate work in the current conversation

The main agent owns the plan, assignments, integration and acceptance. Use [ime-orchestration](.agents/skills/ime-orchestration/SKILL.md) for delegated plans, code reviews and host acceptance. Respect an explicit request for a single agent or a specific number of delegates.

- Discussion or “先出方案，我 review” means research and plan. Read-only investigation can be delegated. Keep implementation for the execution request.
- For “review 一下”, dispatch an independent [ime-reviewer](.codex/agents/ime-reviewer.toml) for the specified diff or module and verify its findings.
- For “执行 plan” or a multi-part fix, proactively delegate implementation to [ime-developer](.codex/agents/ime-developer.toml). Scale the handoff to the risk. For a documentation-only plan, one implementer and the main agent checking commands, links and routing examples usually suffice. For changes to host text, Rime lifetimes, input-source installation or behavior spanning multiple modules, use independent review and [acceptance](.codex/agents/ime-validator.toml) on the integrated change. Within an explicit delegate limit, the main agent covers the remaining checks and identifies who performed them.
- Handle simple factual questions directly. For a handoff, keep the original acceptance conditions and actual evidence per host through rework and final reporting. “通过后提交” makes the requested checks a condition of committing.

## Project skills

Use the focused skills under `.agents/skills/` when their task matches:

- `host-validation`: derive or execute macOS host acceptance checks, especially in TextEdit and Codex.
- `input-state-testing`: reproduce and test sentence, composition, caret, translation cancellation, and replacement behavior.
- `build-debug`: build/package the IME and setup helper, or investigate dependencies, installed identity, stale processes, and memory growth.

These skills are self-contained and use this repository's scripts and requirements. They do not require Playbook, Nodus, company frameworks, external knowledge services, or iOS simulators. Use the available Swift/Xcode tools when they fit the operation; the repository's build, packaging, and check scripts remain authoritative for their respective outputs. The project coordination workflow runs locally without Playbook installation or startup hooks.

## Choose the specification for the task

- Use [daily-use requirements](docs/DAILY_USE_SPEC.md) for settings and typing behavior, and [daily-use acceptance records](docs/DAILY_USE_PLAN.md) for what was tested on a particular build. The [input experience proposal](docs/DAILY_INPUT_EXPERIENCE_SPEC.md) lists planned changes and decisions pending review.
- Use the [Debug testing specification](docs/IME_DEBUG_TESTING_SPEC.md) for development builds, test commands and host evidence. Consult [V1 requirements](docs/V1_REQUIREMENTS.md) for the first-version contract and historical acceptance.
- Use the user's approved scope as the acceptance target. Check current implementation and build-specific host results separately when reporting what works today.
