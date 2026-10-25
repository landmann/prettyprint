#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

test_build_dir="$(mktemp -d)"
trap 'rm -rf "$test_build_dir"' EXIT

sources=($(ls *.swift Components/*.swift | grep -vx main.swift) tests/PopoverBehaviorTest.swift)

swiftc \
    -parse-as-library \
    -target "$(uname -m)-apple-macosx14.0" \
    "${sources[@]}" \
    -o "$test_build_dir/PopoverBehaviorTest"

"$test_build_dir/PopoverBehaviorTest"
