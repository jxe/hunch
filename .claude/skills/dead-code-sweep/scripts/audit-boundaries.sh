#!/usr/bin/env bash
# audit-boundaries.sh — for each named cross-component API surface,
# list every declared symbol with caller counts in four buckets:
# the canonical consumer, the producer (intra-component), the docs
# (parsimony check), and tests (informational only).
#
# The thing this catches that Periphery doesn't:
#   Periphery's "is unused" requires ZERO callers in the module and
#   passes anything with an intra-component caller. Periphery's
#   "redundant public" answers a visibility question, not deletion.
#   Neither flags a symbol that has intra-component callers but no
#   canonical consumer — those are exactly the symbols this audit
#   exists to find.
#
# Usage:
#   audit-boundaries.sh                # all surfaces
#   audit-boundaries.sh <surface>      # one
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
#   SYMBOL                   consumer=N producer=N docs=N test=N
#
#   consumer  files OUTSIDE the producer scope that call this symbol.
#             This is the only column that justifies keeping a symbol
#             on the API surface.
#   producer  files INSIDE the producer scope that mention this symbol
#             (including the declaration line — so producer=1 means
#             "declared but nobody in the producer uses it either").
#   docs      files among the canonical doc set (CLAUDE.md, the two
#             package READMEs) that mention this symbol. consumer=0
#             with docs>0 means the docs are still advertising a
#             dropped/internal API — fix the doc.
#   test      files in App/Tests or Packages/Editor/Tests that call it.
#             *Tests don't justify keeping a symbol.* This column is
#             a heads-up that removing the symbol means removing those
#             tests too.
#
# Verdicts:
#   consumer>0                          live API. If marked `public`,
#                                       keep the `public`. Make sure
#                                       it's listed in the relevant doc.
#   consumer=0  test=0  producer=1      dead. Delete the symbol; sweep
#                                       any doc mentions.
#   consumer=0  test>0  producer=1      test-only API. Delete the
#                                       symbol AND the tests; sweep
#                                       doc mentions.
#   consumer=0  any test  producer>1    intra-component helper, not
#                                       on the cross-component surface.
#                                       Drop the `public` if any; remove
#                                       from any "public API" listing
#                                       in docs. Symbol stays.

set -u
cd "$(git rev-parse --show-toplevel)"

boundary="${1:-all}"

# NSFilePresenter callbacks are protocol-mandated; skip them in the
# enumeration. They live in Clamshell+Presenter.swift (same file as
# the openPage/closePage extension members) but are members of a
# separate presenter class the macOS file system calls — not part of
# the Clamshell API.
SKIP_NAMES_REGEX='^(presentedItemDidChange|presentedItemDidMove|presentedSubitem|presentedSubitemDidAppear|presentedSubitemDidChange)$'

# Canonical doc files for the parsimony check. If a symbol is on the
# cross-component API surface, it should appear here (and only if it's
# consumed). If it's gone or never crossed the boundary, it shouldn't.
DOC_FILES=(
    "CLAUDE.md"
    "App/Sources/Clamshell/README.md"
    "Packages/Editor/README.md"
)

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
#   is non-empty, exclude paths containing it.
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
#   How many of the listed files mention <name>. Used for the producer
#   column (includes the declaration line).
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
    local producer_files="$1"; shift
    local producer_exclude="$1"; shift
    local consumer_paths="$1"; shift

    printf "\n=== %s ===\n" "$label"
    enumerate "$kind" $producer_files | while read -r name; do
        [[ -z "$name" ]] && continue
        local consumer=$(count_files "$name" "$producer_exclude" $consumer_paths)
        local producer=$(count_files_in "$name" $producer_files)
        local docs=$(count_files_in "$name" "${DOC_FILES[@]}")
        local tests=$(count_files "$name" "" App/Tests Packages/Editor/Tests)
        printf "  %-32s consumer=%s producer=%s docs=%s test=%s\n" \
            "$name" "$consumer" "$producer" "$docs" "$tests"
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
