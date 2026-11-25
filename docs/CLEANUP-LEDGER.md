# Cleanup Ledger

`AGENTS.md` describes PrettyPrint's architecture. This ledger records the scope and evidence for source cleanup.

## Intentional patterns

- Direct Bluetooth helpers submit one copy at a time and stop at the first failed transfer. CUPS receives one submission per document with the requested copy count.
- AppKit delegate methods and SwiftUI protocol callbacks can be called by the framework without a direct reference in `Sources/`.

# Feature docs

| Feature | Doc | Surfaces |
| --- | --- | --- |
| Queue and print history | [Features](../README.md#features) | File picker, file drops, copy counts, printer selection and recent prints |
| Layout editor | [Features](../README.md#features) | Images, PDF pages and text on a printable page |
| Printer discovery | [Features](../README.md#features) | CUPS queues, network and USB discovery, reachability |
| Direct Bluetooth printing | [Direct Bluetooth label printing](../README.md#direct-bluetooth-label-printing) | Per-printer helper and per-copy progress |
| Driver finder | [Driver finder](../README.md#driver-finder) | Keychain-backed API routes, CLI lookup and verified driver installers |
| Keyboard shortcuts | [Features](../README.md#features) | Configurable queue, composer, dialog and settings actions |

# Last cleanup

| Area | Paths | Commit | Date | Reviewer |
| --- | --- | --- | --- | --- |
| App | `Sources/App` | `2b14bde6fc7ad78d058e8b3b46a74b6047d4f23d` | 2026-11-25 | gpt-6.2-astra (high) |
| Components / Composer | `Sources/Components/Composer` | `2b14bde6fc7ad78d058e8b3b46a74b6047d4f23d` | 2026-11-25 | gpt-6.2-astra (high) |
| Components / Printers | `Sources/Components/Printers` | `55dabe3d5f79d8d9539b75339ead903982d1e8be` | 2026-11-25 | gpt-6.2-astra (high) |
| Components / Queue | `Sources/Components/Queue` | `2b14bde6fc7ad78d058e8b3b46a74b6047d4f23d` | 2026-11-25 | gpt-6.2-astra (high) |
| Components / Settings | `Sources/Components/Settings` | `2b14bde6fc7ad78d058e8b3b46a74b6047d4f23d` | 2026-11-25 | gpt-6.2-astra (high) |
| Components / Shared | `Sources/Components/Shared` | `2b14bde6fc7ad78d058e8b3b46a74b6047d4f23d` | 2026-11-25 | gpt-6.2-astra (high) |
| Composer | `Sources/Composer` | `2b14bde6fc7ad78d058e8b3b46a74b6047d4f23d` | 2026-11-25 | gpt-6.2-astra (high) |
| Driver finder | `Sources/DriverFinder` | `2b14bde6fc7ad78d058e8b3b46a74b6047d4f23d` | 2026-11-25 | gpt-6.2-astra (high) |
| Printers | `Sources/Printers` | `55dabe3d5f79d8d9539b75339ead903982d1e8be` | 2026-11-25 | gpt-6.2-astra (high) |
| Queue | `Sources/Queue` | `2b14bde6fc7ad78d058e8b3b46a74b6047d4f23d` | 2026-11-25 | gpt-6.2-astra (high) |
| Subprocesses | `Sources/Support` | `2b14bde6fc7ad78d058e8b3b46a74b6047d4f23d` | 2026-11-25 | gpt-6.2-astra (high) |

All 47 Swift files are reviewed and certified across five Codex (`gpt-6.2-astra`, `high`) review rounds, closing with `VERDICT: CLOSED` at `55dabe3d5f79d8d9539b75339ead903982d1e8be`.

## Open findings

None.
