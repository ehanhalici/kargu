#!/usr/bin/env bash
# run_tlc.sh --- Check the Kargu TLA+ specification with TLC.
#
#   ./run_tlc.sh                 exhaustive breadth-first scan (the proof)
#   ./run_tlc.sh --simulate [N]  random simulation of N behaviors (default
#                                100000): a quick smoke test, NOT a proof
#   ./run_tlc.sh <tlc args...>   any other arguments go to TLC as they are
#
# The exit status is 0 only when TLC finished and reported no error.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

TLC_BIN="$(command -v tlc 2>/dev/null || true)"
if [[ -z "${TLC_BIN}" ]]; then
    if command -v nix-shell >/dev/null 2>&1; then
        exec nix-shell "${SCRIPT_DIR}/../shell.nix" --run \
            "bash \"${SCRIPT_DIR}/run_tlc.sh\" $(printf '%q ' "$@")"
    fi
    echo "ERROR: tlc (TLA+ model checker) not found in PATH and nix-shell unavailable." >&2
    exit 1
fi

METADIR="$(mktemp -d "${TMPDIR:-/tmp}/kargu-tlc.XXXXXX")"
LOG="${METADIR}/tlc.log"
trap 'rm -rf "${METADIR}"' EXIT

if [[ $# -eq 0 ]]; then
    MODE="exhaustive scan"
    ARGS=(-workers auto -nowarning -metadir "${METADIR}" MC.tla)
elif [[ "$1" == "--simulate" ]]; then
    MODE="random simulation (not a proof)"
    ARGS=(-workers auto -nowarning -metadir "${METADIR}" -simulate "num=${2:-100000}" MC.tla)
else
    MODE="custom arguments"
    ARGS=("$@")
fi

echo "=== TLC on Kargu: ${MODE} ==="
echo "Specification: MC.tla (KarguLoop, KarguProtocol, KarguCircuit, KarguTools, KarguState)"
echo "TLC Binary:    ${TLC_BIN}"
echo "---------------------------------------------------------------"

status=0
"${TLC_BIN}" "${ARGS[@]}" 2>&1 | tee "${LOG}" || status=$?
# `pipefail` makes the pipeline fail when TLC fails, not only when tee does.

echo "---------------------------------------------------------------"
if [[ ${status} -ne 0 ]] || grep -qE "^Error:|Invariant .* is violated|Deadlock reached" "${LOG}"; then
    echo "TLC FAILED (exit ${status}): see the trace above." >&2
    exit 1
fi
if ! grep -q "Model checking completed. No error has been found\|Finished in" "${LOG}"; then
    echo "TLC did not finish: no verdict." >&2
    exit 1
fi
echo "TLC finished without error (${MODE})."
