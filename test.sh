#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

test_build_dir="$(mktemp -d)"
trap 'rm -rf "$test_build_dir"' EXIT

sources=()
while IFS= read -r file; do sources+=("$file"); done < <(find Sources -name '*.swift' ! -path Sources/App/PrettyPrintApp.swift | sort)

swiftc \
    -parse-as-library \
    -target "$(uname -m)-apple-macosx14.0" \
    "${sources[@]}" Tests/PrettyPrintTests.swift \
    -o "$test_build_dir/PrettyPrintTests"

"$test_build_dir/PrettyPrintTests"
