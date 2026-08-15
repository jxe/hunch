#!/bin/sh

set -eu

quagmire_script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
quagmire_package_dir=$(dirname -- "$quagmire_script_dir")
quagmire_derived_root=${QUAGMIRE_DERIVED_DATA_ROOT:-${TMPDIR:-/tmp}/quagmire-verify}

echo "Running Quagmire package tests"
swift package --package-path "$quagmire_package_dir" clean
swift test --package-path "$quagmire_package_dir"

echo "Building Quagmire for macOS"
(
    cd "$quagmire_package_dir"
    xcodebuild \
        -scheme Quagmire \
        -destination 'generic/platform=macOS' \
        -derivedDataPath "$quagmire_derived_root/macos" \
        CODE_SIGNING_ALLOWED=NO \
        clean build
)

echo "Building Quagmire for iOS Simulator"
(
    cd "$quagmire_package_dir"
    xcodebuild \
        -scheme Quagmire \
        -destination 'generic/platform=iOS Simulator' \
        -derivedDataPath "$quagmire_derived_root/ios-simulator" \
        CODE_SIGNING_ALLOWED=NO \
        clean build
)
