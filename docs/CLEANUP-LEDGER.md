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
| LocalNetworkAccessGuide | `Sources/Components/Printers/LocalNetworkAccessGuide.swift` | `2b14bde6fc7ad78d058e8b3b46a74b6047d4f23d` | 2026-11-25 | gpt-6.2-astra (high) |
| LocalNetworkAccessNotice | `Sources/Components/Printers/LocalNetworkAccessNotice.swift` | `2b14bde6fc7ad78d058e8b3b46a74b6047d4f23d` | 2026-11-25 | gpt-6.2-astra (high) |
| OpenPrivacySettingsButton | `Sources/Components/Printers/OpenPrivacySettingsButton.swift` | `2b14bde6fc7ad78d058e8b3b46a74b6047d4f23d` | 2026-11-25 | gpt-6.2-astra (high) |
| Components / Queue | `Sources/Components/Queue` | `2b14bde6fc7ad78d058e8b3b46a74b6047d4f23d` | 2026-11-25 | gpt-6.2-astra (high) |
| Components / Settings | `Sources/Components/Settings` | `2b14bde6fc7ad78d058e8b3b46a74b6047d4f23d` | 2026-11-25 | gpt-6.2-astra (high) |
| Components / Shared | `Sources/Components/Shared` | `2b14bde6fc7ad78d058e8b3b46a74b6047d4f23d` | 2026-11-25 | gpt-6.2-astra (high) |
| Composer | `Sources/Composer` | `2b14bde6fc7ad78d058e8b3b46a74b6047d4f23d` | 2026-11-25 | gpt-6.2-astra (high) |
| Driver finder | `Sources/DriverFinder` | `2b14bde6fc7ad78d058e8b3b46a74b6047d4f23d` | 2026-11-25 | gpt-6.2-astra (high) |
| PrinterSelectionPolicy | `Sources/Printers/PrinterSelectionPolicy.swift` | `2b14bde6fc7ad78d058e8b3b46a74b6047d4f23d` | 2026-11-25 | gpt-6.2-astra (high) |
| PrinterStatus | `Sources/Printers/PrinterStatus.swift` | `2b14bde6fc7ad78d058e8b3b46a74b6047d4f23d` | 2026-11-25 | gpt-6.2-astra (high) |
| Printers | `Sources/Printers/Printers.swift` | `2b14bde6fc7ad78d058e8b3b46a74b6047d4f23d` | 2026-11-25 | gpt-6.2-astra (high) |
| Queue | `Sources/Queue` | `2b14bde6fc7ad78d058e8b3b46a74b6047d4f23d` | 2026-11-25 | gpt-6.2-astra (high) |
| Subprocesses | `Sources/Support` | `2b14bde6fc7ad78d058e8b3b46a74b6047d4f23d` | 2026-11-25 | gpt-6.2-astra (high) |

The reviewer read all 47 Swift files in round one and checked the fixes in round two. The rows above cover 44 files. The three files below changed after the second round.

## Open findings

| File | Finding | Needed | Date |
| --- | --- | --- | --- |
| `Sources/Printers/PrinterReachability.swift` | R1-09, `target(forDeviceURI:)` now treats an empty USB serial as absent. | Re-review after change | 2026-11-25 |
| `Sources/Printers/PrinterSetup.swift` | R1-08, `discover(excludingNames:)` now propagates failed CUPS queries. | Re-review after change | 2026-11-25 |
| `Sources/Components/Printers/AddPrinterWindow.swift` | R1-08, `search()` clears stale discovery results and displays a retry message when a CUPS lookup fails. | Re-review after change | 2026-11-25 |
