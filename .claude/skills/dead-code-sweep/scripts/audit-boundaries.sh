#!/usr/bin/env bash
# audit-boundaries.sh — list every declared symbol on a named cross-
# component API surface with caller counts in three buckets: the
# canonical consumer, the producer (intra-component), and tests.
#
# What this catches that Periphery and triage-public.sh miss:
#   Periphery's "is unused" requires ZERO callers across the module.
#   It happily passes any symbol with an intra-component caller (other
#   file in the same producer dir) or a test-only caller. And triage-
#   public.sh is a different question — visibility ("redundant
#   public"), not deletion ("is this API surface actually consumed").
#
#   For each named surface in this repo, the question is: does the
#   canonical consumer (host, editor, dispatch sites) actually invoke
#   each declared symbol? If not, the symbol is either an intra-
#   component helper masquerading as API, or genuinely dead.
#
# Usage:
#   audit-boundaries.sh                # run all surfaces
#   audit-boundaries.sh <surface>      # run one
#
# Surfaces:
#   clamshell      Methods on `Clamshell` and its extensions.
#                  Consumer: rest of App/Sources (excluding Clamshell dir).
#   editor-host    `EditorHost` protocol methods.
#                  Consumer: rest of Editor SPM (the editor invokes them).
#   editor-action  `EditorAction` enum cases.
#                  Consumer: anywhere except the declaration file.
#
# Output per symbol:
#   SYMBOL                   consumer=N producer=N test=N
#
#   consumer  files OUTSIDE the producer scope that call this symbol.
#   producer  files INSIDE the producer scope that mention this symbol
#             (including the declaration line — so producer=1 means
#             "declared but nobody in the producer uses it either").
#   test      files in App/Tests or Packages/Editor/Tests that call it.
#
# Verdicts:
#   consumer>0                            live API. Leave alone.
#   consumer=0 && test>0                  test-only — delete the symbol
#                                         AND its tests (same rule as
#                                         Periphery's test-only bucket).
#   consumer=0 && test=0 && producer>1    intra-component helper, not
#                                         actually on the boundary.
#                                         Consider `private`, or leave
#                                         (visibility isn't the focus
#                                         of this audit).
#   consumer=0 && test=0 && producer=1    dead — only the declaration
#                                         mentions it. Delete.

set -u
cd "$(git rev-parse --show-toplevel)"

boundary="${1:-all}"

# NSFilePresenter callbacks are protocol-mandated; skip them in the
# enumeration. They live in the same file as Clamshell+Presenter
# (Clamshell extension) but are members of a separate presenter class
# that the macOS file system calls — not part of the Clamshell API.
SKIP_NAMES_REGEX='^(presentedItemDidChange|presentedItemDidMove|presentedSubitem|presentedSubitemDidAppear|presentedSubitemDidChange)$'

# enumerate <kind> <files...>
#   kind: "func" or "case"
enumerate() {
    local kind="$1"; shift
    case "$kind" in
        func)
            grep -hE "^[[:space:]]+(@[A-Za-z]+[[:space:]]+|public[[:space:]]+|internal[[:space:]]+|nonisolated[[:space:]]+|@discardableResult[[:space:]]+|static[[:space:]]+)*func[[:space:]]+[a-zA-Z_]+" "$@" 2>/dev/null \
                | sed -E 's/.*func[[:space:]]+([a-zA-Z_]+).*/\1/'
            ;;
        case)
            grep -hE "^[[:space:]]+case[[:space:]]+[a-zA-Z_]+" "$@" 2>/dev/null \
                | sed -E 's/.*case[[:space:]]+([a-zA-Z_]+).*/\1/'
            ;;
    esac \
        | grep -vE "$SKIP_NAMES_REGEX" \
        | sort -u
}

# count_files <name> <exclude-path-fragment> <paths...>
#   Count files matching <name> in <paths>. If <exclude-path-fragment>
#   is non-empty, exclude paths containing it. Matches `.name` (member
#   access / enum case) or `name(` (call).
count_files() {
    local name="$1"; shift
    local exclude="$1"; shift
    if [[ -z "$exclude" ]]; then
        grep -rlE "\.${name}\b|\b${name}\(" "$@" 2>/dev/null \
            | wc -l | tr -d ' '
    else
        grep -rlE "\.${name}\b|\b${name}\(" "$@" 2>/dev/null \
            | grep -v "$exclude" \
            | wc -l | tr -d ' '
    fi
}

# count_files_in <name> <files...>
#   Count how many of the listed files mention <name>. Used for the
#   producer column (includes the declaration line).
count_files_in() {
    local name="$1"; shift
    local hits=0
    for f in "$@"; do
        if grep -qE "\b${name}\b" "$f" 2>/dev/null; then
            hits=$((hits + 1))
        fi
    done
    echo "$hits"
}

audit() {
    local label="$1"; shift
    local kind="$1"; shift
    local producer_files="$1"; shift     # space-separated
    local producer_exclude="$1"; shift   # path fragment to exclude from consumer count
    local consumer_paths="$1"; shift     # space-separated paths to count consumer in

    printf "\n=== %s ===\n" "$label"
    enumerate "$kind" $producer_files | while read -r name; do
        [[ -z "$name" ]] && continue
        local consumer=$(count_files "$name" "$producer_exclude" $consumer_paths)
        local producer=$(count_files_in "$name" $producer_files)
        local tests=$(count_files "$name" "" App/Tests Packages/Editor/Tests)
        printf "  %-32s consumer=%s producer=%s test=%s\n" \
            "$name" "$consumer" "$producer" "$tests"
    done
}

run() {
    case "$1" in
        clamshell)
            audit "clamshell — Clamshell API (consumer: rest of App/Sources)" \
                "func" \
                "App/Sources/Clamshell/Clamshell.swift App/Sources/Clamshell/Clamshell+Reconcile.swift App/Sources/Clamshell/Clamshell+Presenter.swift" \
                "App/Sources/Clamshell/" \
                "App/Sources"
            ;;
        editor-host)
            audit "editor-host — EditorHost protocol methods (consumer: Editor SPM)" \
                "func" \
                "Packages/Editor/Sources/Editor/EditorHost.swift" \
                "EditorHost.swift" \
                "Packages/Editor/Sources"
            ;;
        editor-action)
            audit "editor-action — EditorAction cases (consumer: anywhere)" \
                "case" \
                "Packages/Editor/Sources/Editor/EditorCommands.swift" \
                "EditorCommands.swift" \
                "App/Sources Packages/Editor/Sources"
            ;;
        *)
            echo "Unknown surface: $1" >&2
            echo "Available: clamshell, editor-host, editor-action, all" >&2
            return 1
            ;;
    esac
}

if [[ "$boundary" == "all" ]]; then
    run clamshell
    run editor-host
    run editor-action
else
    run "$boundary"
fi
