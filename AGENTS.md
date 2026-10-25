# PrettyPrint

PrettyPrint is a macOS menu bar app written in Swift and SwiftUI, built with `swiftc` scripts and no package manager or dependencies.

## Commands

- `bash build.sh` builds `build/PrettyPrint.app` for this Mac.
- `bash test.sh` compiles every source except `Sources/App/PrettyPrintApp.swift` with `Tests/PrettyPrintTests.swift` and runs it. Every check prints a `PASS:` line; a failure stops with `fatalError`.
- `bash release.sh` builds a universal, ad-hoc signed `build/PrettyPrint.dmg` and prints the `gh release create` command.

## Layout

- `Sources/App` holds the entry point, app delegate, popover, keyboard shortcuts, and file picking.
- `Sources/Queue` holds the print queue, print jobs, history, and imported documents.
- `Sources/Printers` holds the CUPS printer list, status, reachability, selection, and printer setup.
- `Sources/DriverFinder` holds the LLM driver lookup and installer verification.
- `Sources/Composer` holds the page layout model and rendering.
- `Sources/Support` holds `ProcessRunner`.
- `Sources/Components` holds all SwiftUI views, in `Shared`, `Queue`, `Composer`, `Printers`, and `Settings`.
- `Resources` holds `Info.plist` and the app icon. `docs` is the GitHub Pages site.

## Code

- Code is comment-free. Names and structure carry the meaning.
- The scripts compile every `.swift` file under `Sources`, so new files need no registration.
- Printing goes through CUPS (`lp`, `lpstat`, `lpoptions`, `lpinfo`, `lpadmin`). Run external tools through `ProcessRunner` with an absolute path and an argument array, never a shell string.
- A printer shows Ready only after `PrinterReachability` confirms it can be reached; printers it can't confirm are Not available and can't be selected.
- API keys live only in the Keychain (`DriverFinderKey`). Never write them to `UserDefaults`, files, or logs.
- Driver installers open only after `DriverInstaller` confirms Gatekeeper accepts them as notarized Developer ID software, re-checks just before opening, and the user approves. The Claude Code route runs in `--safe-mode` with only web tools.
- Older Swift compilers on CI fail on long view bodies and mixed `CGFloat`/`Double` math. Keep view bodies split into small named pieces and number types explicit.

## After edits

Run `bash test.sh` and `bash build.sh`. To try the build, quit the running PrettyPrint, replace `~/Applications/PrettyPrint.app` with `build/PrettyPrint.app`, check it with `codesign --verify --deep --strict`, open it, and confirm exactly one `PrettyPrint` process is running. Restarting clears the in-memory queue.
