#!/usr/bin/env bash
# Run one Godot check with a time limit, a retained transcript, and an optional full-line ERE.
set -euo pipefail

limit=$1
log=$2
marker=$3
shift 3

timeout --kill-after=10s "$limit" "$@" 2>&1 | tee "$log"

# Tests that exercise failed saves assert the expected result themselves. Engine errors
# and script errors still fail even if the test prints a success marker and exits zero.
if grep -nE 'SCRIPT ERROR:|Parse Error:|^(USER )?ERROR:' "$log"; then
    exit 1
elif [[ $? != 1 ]]; then
    exit 1
fi
if [[ "$marker" != "-" ]] && ! grep -Exq -- "$marker" "$log"; then
    printf 'Expected success line /%s/ is missing from %s\n' "$marker" "$log" >&2
    exit 1
fi
