#!/usr/bin/env bash
# Offline source ERT; the caller builds the binary from this checkout first.
set -euo pipefail
cd "$(dirname "$0")/../.."
mode="${1:-full}"
case "$mode" in full|bridge) ;; *) echo "Expected full or bridge" >&2; exit 2;; esac
binary="$(realpath "${KARGU_CORE_TEST_BINARY:?Set the freshly built native binary}")"
[[ -x "$binary" ]]
# Never let a previous compile hide the checkout's source, including child Emacs.
if rg --files --hidden --no-ignore -g '*.elc' -g '!kargu-core/target/**' -g '!.git/**' | rg .; then
    echo "Remove stale checkout bytecode before running source ERT" >&2
    exit 1
fi
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
args=(--batch -Q -L .)
if [[ "$mode" == full ]]; then
    # CI installs company explicitly; missing fixtures must fail, never skip.
    args+=(-L "${KARGU_CI_COMPANY_DIR:?Set the installed company package directory}")
    args+=(-L "${KARGU_CI_DAPE_DIR:?Set the pinned Dape source directory}")
    args+=(--eval "(progn (require 'company) (require 'dape))" -l tests/run-tests.el)
else
    args+=(-l tests/test-bridge.el -l tests/test-bridge-jobs.el -f ert-run-tests-batch-and-exit)
fi
env -i PATH="$PATH" LANG=C.UTF-8 HOME="$scratch" XDG_CONFIG_HOME="$scratch/config" \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
    KARGU_CORE_TEST_BINARY="$binary" emacs "${args[@]}" 2>&1 | tee "$scratch/ert.log"
if rg -q '^[[:space:]]+(SKIPPED|skipped)[[:space:]]|^[0-9]+ skipped results' "$scratch/ert.log"; then
    echo "Source ERT skipped tests; fixture coverage is incomplete" >&2
    exit 1
fi
