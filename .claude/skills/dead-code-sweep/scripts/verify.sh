#!/usr/bin/env bash
# Run all four verification gates in parallel: Editor SPM tests, macOS
# build, iOS Simulator build, HunchUnitTests. Streams each gate's
# output to a temp log; on completion prints a PASS/FAIL summary and
# tails the failure logs if anything failed.
#
# Exit code: 0 if all pass, 1 if any failed. Don't commit until all four
# pass.

set -u
cd "$(git rev-parse --show-toplevel)"

LOGDIR=$(mktemp -d -t hunch-verify.XXXXXX)
trap "rm -rf $LOGDIR" EXIT

(swift test --package-path Packages/Editor) \
    > "$LOGDIR/editor-test.log" 2>&1 &
PID_editor=$!

(xcodebuild -project Hunch.xcodeproj -scheme Hunch \
    -destination 'platform=macOS' -configuration Debug build) \
    > "$LOGDIR/macos-build.log" 2>&1 &
PID_macos=$!

(xcodebuild -project Hunch.xcodeproj -scheme Hunch \
    -destination 'generic/platform=iOS Simulator' -configuration Debug build) \
    > "$LOGDIR/ios-build.log" 2>&1 &
PID_ios=$!

(xcodebuild -project Hunch.xcodeproj -scheme Hunch \
    -destination 'platform=macOS' test -only-testing HunchUnitTests) \
    > "$LOGDIR/hunch-unit-tests.log" 2>&1 &
PID_unit=$!

wait $PID_editor; rc_editor=$?
wait $PID_macos; rc_macos=$?
wait $PID_ios; rc_ios=$?
wait $PID_unit; rc_unit=$?

print_row() {
    local rc=$1 name=$2
    if [ "$rc" -eq 0 ]; then
        printf "PASS  %s\n" "$name"
    else
        printf "FAIL  %s  (rc=%s)\n" "$name" "$rc"
    fi
}

print_row $rc_editor "editor-test       (swift test --package-path Packages/Editor)"
print_row $rc_macos  "macos-build       (xcodebuild build, platform=macOS)"
print_row $rc_ios    "ios-build         (xcodebuild build, iOS Simulator)"
print_row $rc_unit   "hunch-unit-tests  (xcodebuild test -only-testing HunchUnitTests)"

failed=0
[ $rc_editor -ne 0 ] && failed=1
[ $rc_macos  -ne 0 ] && failed=1
[ $rc_ios    -ne 0 ] && failed=1
[ $rc_unit   -ne 0 ] && failed=1

if [ "$failed" -ne 0 ]; then
    echo ""
    echo "=== Tail of failures ==="
    [ $rc_editor -ne 0 ] && { echo "--- editor-test ---";      tail -n 30 "$LOGDIR/editor-test.log";      echo ""; }
    [ $rc_macos  -ne 0 ] && { echo "--- macos-build ---";      tail -n 30 "$LOGDIR/macos-build.log";      echo ""; }
    [ $rc_ios    -ne 0 ] && { echo "--- ios-build ---";        tail -n 30 "$LOGDIR/ios-build.log";        echo ""; }
    [ $rc_unit   -ne 0 ] && { echo "--- hunch-unit-tests ---"; tail -n 30 "$LOGDIR/hunch-unit-tests.log"; echo ""; }
    exit 1
fi
