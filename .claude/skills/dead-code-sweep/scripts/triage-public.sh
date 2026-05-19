#!/usr/bin/env bash
# Triage the Editor package's "declared public, but not used outside of
# Editor" findings against the Hunch app target. Periphery scanning
# Editor alone can't see App/Sources consuming Editor — so it flags
# many genuinely cross-module symbols as redundant. This script runs
# the no-retain scan, then for each flagged symbol greps App/Sources
# to see whether the app actually consumes it.
#
# Output per symbol is either:
#   DROP:     <sym>     (zero hits in App/Sources — safe to downgrade)
#   KEEP (N): <sym>     (N files in App/Sources reference it — leave public)
#   MANUAL:   <sym>     (an init — check the parent type's row to decide)
#
# Spot-check KEEP rows for doc-comment-only hits (README, CLAUDE.md
# refs masquerade as usages). Anything in DROP is safe to convert
# `public` → `internal`. MANUAL rows are inits: Swift call sites use
# the parent type name, not `init`, so the grep can't tell — look at
# the parent type's row to decide (if the type is KEEP, its inits
# should usually be KEEP too).

set -u
cd "$(git rev-parse --show-toplevel)"

CONFIG=$(mktemp -t editor-no-retain.XXXXXX).yml
cat > "$CONFIG" <<'EOF'
retain_public: false
retain_swift_ui_previews: true
relative_results: true
disable_update_check: true
EOF
trap "rm -f $CONFIG" EXIT

( cd Packages/Editor && periphery scan --config "$CONFIG" ) 2>&1 \
  | grep "declared public, but not used outside" \
  | sed -E "s/.*'([^']+)'.*/\1/" \
  | sort -u \
  | while read selector; do
      # init(*) — defer to parent type's verdict; the call site uses
      # the type name, not `init`, so the grep can't decide.
      case "$selector" in
          init\(*\))
              printf "MANUAL:   %s  (init — check parent type's row)\n" "$selector"
              continue
              ;;
      esac
      # Periphery's selector format includes the parameter list for
      # functions/inits (`body(size:weight:)`). Call sites use the
      # bare name with concrete arguments (`NotionStyle.body(size: 13)`),
      # so for selectors with `(` we grep `<bare>\(` to match call
      # sites. Properties / types have no `(` and use `\b<bare>\b`.
      bare="${selector%%(*}"
      if [[ "$selector" == *"("* ]]; then
          pattern="${bare}\\("
      else
          pattern="\\b${bare}\\b"
      fi
      hits=$(grep -rlE "$pattern" App/Sources 2>/dev/null | wc -l | tr -d ' ')
      if [ "$hits" = "0" ]; then
          printf "DROP:     %s\n" "$selector"
      else
          printf "KEEP (%s): %s\n" "$hits" "$selector"
      fi
  done | sort
