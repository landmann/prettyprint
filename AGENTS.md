# PrettyPrint

PrettyPrint is a macOS menu bar app written in Swift and SwiftUI, built with `swiftc` scripts and no package manager or dependencies.

## Commands

- `bash build.sh` builds `PrettyPrint.app` for this Mac.
- `bash test.sh` compiles every source except `main.swift` with `tests/PopoverBehaviorTest.swift` and runs it. Every check prints a `PASS:` line; a failure stops with `fatalError`.
- `bash release.sh` builds a universal, ad-hoc signed `PrettyPrint.dmg` and prints the `gh release create` command.

## Code

- Code is comment-free. Names and structure carry the meaning.
- New source files are picked up by the scripts automatically. Shared UI pieces go in `Components/`.
- Printing goes through CUPS (`lp`, `lpstat`, `lpoptions`, `lpinfo`, `lpadmin`). Run external tools through `ProcessRunner` with an absolute path and an argument array, never a shell string.
- API keys live only in the Keychain (`DriverFinderKey`). Never write them to `UserDefaults`, files, or logs.
- Driver installers open only after `DriverInstaller` confirms Gatekeeper accepts them as notarized Developer ID software, re-checks just before opening, and the user approves. The Claude Code route runs in `--safe-mode` with only web tools.

## After edits

Run `bash test.sh` and `bash build.sh`. To try the build, quit the running PrettyPrint, replace `~/Applications/PrettyPrint.app` with the new build, check it with `codesign --verify --deep --strict`, open it, and confirm exactly one `PrettyPrint` process is running. Restarting clears the in-memory queue.
