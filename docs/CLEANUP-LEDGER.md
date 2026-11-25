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
| PrinterReachability | `Sources/Printers/PrinterReachability.swift` | `2b14bde6fc7ad78d058e8b3b46a74b6047d4f23d` | 2026-11-25 | gpt-6.2-astra (high) |
| PrinterSelectionPolicy | `Sources/Printers/PrinterSelectionPolicy.swift` | `2b14bde6fc7ad78d058e8b3b46a74b6047d4f23d` | 2026-11-25 | gpt-6.2-astra (high) |
| PrinterStatus | `Sources/Printers/PrinterStatus.swift` | `2b14bde6fc7ad78d058e8b3b46a74b6047d4f23d` | 2026-11-25 | gpt-6.2-astra (high) |
| Queue | `Sources/Queue` | `2b14bde6fc7ad78d058e8b3b46a74b6047d4f23d` | 2026-11-25 | gpt-6.2-astra (high) |
| Subprocesses | `Sources/Support` | `2b14bde6fc7ad78d058e8b3b46a74b6047d4f23d` | 2026-11-25 | gpt-6.2-astra (high) |

The reviewer read all 47 Swift files in round one, checked fixes in round two, and confirmed `R1-09` (`PrinterReachability.swift`) in round three. The rows above cover 44 files. The three files below were updated in `8747942` after round three (budget end) to treat CUPS `"No destinations added."` as an empty configured list and propagate `lpstat -e` / `lpoptions` failures to the retry UI.

## Open findings

| File | Finding | Needed | Date |
| --- | --- | --- | --- |
| `Sources/Printers/PrinterSetup.swift` | R1-08 post-Round-3 fix (`8747942`): uses `PrinterDirectory.lpstatOutput(["-v"])` so zero-printer Macs still discover printers. | Re-review after change | 2026-11-25 |
| `Sources/Printers/Printers.swift` | R1-08 post-Round-3 fix (`8747942`): added `lpstatOutput` (`LC_ALL=C` + `"No destinations added"` check) and `configuredNames()` propagating lookup failures. | Re-review after change | 2026-11-25 |
| `Sources/Components/Printers/AddPrinterWindow.swift` | R1-08 post-Round-3 fix (`8747942`): `search()` calls `PrinterDirectory.configuredNames()` and shows retry UI on failure. | Re-review after change | 2026-11-25 |
