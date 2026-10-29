#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .local/tests
swiftc ios/EverysightPlayground/MessageLayout.swift tests/MessageLayoutTests.swift -o .local/tests/message-layout
.local/tests/message-layout
