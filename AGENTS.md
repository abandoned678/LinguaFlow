# LinguaFlow agent rules

These rules apply to the whole repository.

## Product boundaries

- LinguaFlow is a macOS-first input method. Do not add Windows TSF code.
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
- Run both `linguaflow-core-checks` and `linguaflow-rime-checks` after input changes.
- Build both `LinguaFlowIME` and `LinguaFlowSetup` after UI or translation changes.
- Do not copy GPL frontend code from Squirrel or MetasequoiaIME. Architectural study is allowed; implementation must remain original.
- Preserve upstream license files and notices for all vendored/submodule data.

## Project skills

Use the focused skills under `.agents/skills/` when their task matches:

- `linguaflow-host-validation`: derive or execute macOS host acceptance checks, especially in TextEdit and Codex.
- `linguaflow-state-testing`: reproduce and test sentence, composition, caret, translation cancellation, and replacement behavior.
- `linguaflow-build-debug`: build/package the IME and setup helper, or investigate dependencies, installed identity, stale processes, and memory growth.

These skills are self-contained and use this repository's scripts and requirements. They do not require Playbook, Nodus, company frameworks, external knowledge services, or iOS simulators. Use the available Swift/Xcode tools when they fit the operation; the repository's build, packaging, and check scripts remain authoritative for their respective outputs. No full Playbook lifecycle, delegation, or startup hook is required.

Read `docs/需求与待办.md` for the agreed first-version behavior. Requirements describe the target, not proof that the existing upstream implementation already supports it. Keep implementation evidence and host verification separate.
