#!/bin/bash
# Compiler-warnings gate: fails when a build log has more warnings than the baseline.
#
#   scripts/check_warnings.sh <build-log>             check an existing log
#   scripts/check_warnings.sh -- swift build -j 4     run the command, tee its output, check it
#
# Baseline: scripts/warnings-baseline.txt (a single number; override with OJ_WARNING_BASELINE).
# A clean build of every target (tests included) was warning-free when the gate was added,
# so the baseline is 0: any new warning fails. If a toolchain update brings unavoidable
# warnings, fix them or raise the baseline in the same commit and say why.
#
# Counted: unique compiler diagnostics of the form `<file>:<line>:<col>: warning: ...` from
# the repo's own Sources/ and Tests/ (the location line, not the source excerpt underneath).
# Linker / tool warnings without a location are listed but do not count.
#
# Note: SwiftPM does not replay warnings for files it does not recompile, so check a CLEAN
# build when you want the full picture (`rm -rf .build` first). On an incremental build
# the gate still catches warnings in everything that was rebuilt.
set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASELINE_FILE="$PROJECT_DIR/scripts/warnings-baseline.txt"

if [ "${1:-}" = "--" ]; then
    shift
    [ $# -gt 0 ] || { echo "usage: $0 -- <build command...>" >&2; exit 2; }
    LOG="$(mktemp "${TMPDIR:-/tmp}/oj-build-log.XXXXXX")"
    trap 'rm -f "$LOG"' EXIT
    "$@" 2>&1 | tee "$LOG"
    status="${PIPESTATUS[0]}"
    if [ "$status" -ne 0 ]; then
        echo "check_warnings: build command failed (exit $status)" >&2
        exit "$status"
    fi
elif [ $# -eq 1 ] && [ -f "$1" ]; then
    LOG="$1"
else
    awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0" >&2
    exit 2
fi

baseline="${OJ_WARNING_BASELINE:-}"
if [ -z "$baseline" ]; then
    baseline="$(tr -d ' \t\r\n' < "$BASELINE_FILE" 2>/dev/null)"
fi
[[ "$baseline" =~ ^[0-9]+$ ]] || { echo "check_warnings: invalid baseline '$baseline'" >&2; exit 2; }

# Strip ANSI colours, keep `<path>:<line>:<col>: warning:` lines under Sources/ or Tests/,
# make paths repo-relative so local and CI output compare, and de-duplicate (the same
# diagnostic is printed once per architecture / build plan).
WARNINGS="$(sed -e $'s/\x1b\\[[0-9;]*m//g' "$LOG" \
    | grep -E '^[^ ].*:[0-9]+:[0-9]+: warning: ' \
    | sed -e "s#^$PROJECT_DIR/##" -e 's#^.*/\(Sources/\)#\1#' -e 's#^.*/\(Tests/\)#\1#' \
    | grep -E '^(Sources|Tests)/' \
    | sort -u)"
OTHER="$(sed -e $'s/\x1b\\[[0-9;]*m//g' "$LOG" \
    | grep -E '(^|[[:space:]])warning: ' \
    | grep -vE '^[^ ].*:[0-9]+:[0-9]+: warning: ' \
    | grep -vE '^[[:space:]]*[|`]' \
    | sort -u)"

if [ -n "$WARNINGS" ]; then count="$(printf '%s\n' "$WARNINGS" | wc -l | tr -d ' ')"; else count=0; fi

if [ -n "$OTHER" ]; then
    echo "Tool warnings without a source location (not counted):"
    printf '%s\n' "$OTHER" | sed 's/^/  /'
fi
if [ "$count" -gt 0 ]; then
    echo "Compiler warnings ($count):"
    printf '%s\n' "$WARNINGS" | sed 's/^/  /'
    if [ -n "${GITHUB_ACTIONS:-}" ]; then
        # Annotate the PR diff: ::warning file=...,line=...,col=...::message
        printf '%s\n' "$WARNINGS" | sed -E 's/^([^:]+):([0-9]+):([0-9]+): warning: (.*)$/::warning file=\1,line=\2,col=\3::\4/'
    fi
fi

if [ "$count" -gt "$baseline" ]; then
    echo "check_warnings: $count compiler warning(s), baseline is $baseline. Fix the new warning(s)." >&2
    exit 1
fi
if [ "$count" -lt "$baseline" ]; then
    echo "check_warnings: $count warning(s), below the baseline of $baseline. Lower scripts/warnings-baseline.txt to $count."
else
    echo "check_warnings: $count compiler warning(s) (baseline $baseline)"
fi
