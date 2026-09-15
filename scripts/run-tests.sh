#!/usr/bin/env bash
# Runs the core test suite, with a clear message when XCTest is unavailable.
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ "$(uname -s)" == "Darwin" ]] && ! xcrun --find xctest >/dev/null 2>&1; then
  echo "Cannot run the tests: XCTest is missing." >&2
  echo >&2
  echo "XCTest ships with Xcode, not with the Command Line Tools, so 'swift test' cannot" >&2
  echo "build the test target. The app itself does not need Xcode: 'make app' works as is." >&2
  echo >&2
  if [[ -d /Applications/Xcode.app ]]; then
    echo "Xcode is installed here, so point the toolchain at it once:" >&2
    echo >&2
    echo "    sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
    echo >&2
    echo "Then run 'make test' again." >&2
  else
    echo "Install Xcode from the App Store, then run:" >&2
    echo >&2
    echo "    sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
    echo >&2
    echo "Without Xcode, skip the tests and use 'make app' plus 'lrsync-check'." >&2
  fi
  exit 1
fi

exec swift test "$@"
