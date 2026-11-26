# Contributing

Great that you want to make Mochi Squad better.

## Before you start

For larger changes, please open an issue first so we can agree on the direction. Small fixes are welcome directly as a pull request.

## Developing

```bash
swift build          # build
./tools/test.sh      # all tests (Swift and Python)
./install.sh         # install to ~/Applications
```

You need macOS 14 and the Xcode command line tools with Swift 6 or newer; Xcode itself is not required.

## Guidelines

- **Small and readable.** A clear function beats a clever one. Comments explain the why.
- **Security first.** An agent's rights are made in `scripts/launcher.py` (rules and sandbox), `Sessions/AgentSession.swift` (session folder, outbox) and `Sessions/SessionManager.swift` (tools, limits). Changes there need tests and a look at [SECURITY.md](SECURITY.md).
- **No new dependencies** without discussion. The Python helpers use only the standard library (Python 3.9). The one exception is the optional WhatsApp link, which needs Node.js and one pinned library.
- **Language.** Code, comments, commit messages and docs are in English. Every text the user sees exists in English and German and sits at the call site: `t("English", "Deutsch")` in Swift, `common.t(...)` in Python. Texts that agents read (briefings, receipts, tool answers) are English only; agents answer in the language they are addressed in.
- **Interface.** Colours and shapes come from `Sources/MochiSquad/UI/Theme.swift`.
- **Tests.** New logic gets tests; `./tools/test.sh` must be green.

## Layout

| Path | Content |
|---|---|
| `Sources/MochiSquad/Core` | Data model, storage, language |
| `Sources/MochiSquad/Sessions` | Sessions, collaboration, routines, tool server, messengers |
| `Sources/MochiSquad/UI` | Interface |
| `scripts/` | Python helpers that are copied into the app; `scripts/whatsapp/` is the Node helper for WhatsApp |
| `Tests/MochiSquadTests`, `Tests/python` | Swift and Python tests |
