#!/usr/bin/env bash
# run_tlc.sh --- Check the Kargu TLA+ specification with TLC.
#
#   ./run_tlc.sh                 exhaustive breadth-first scan (the proof)
#   ./run_tlc.sh --plan          exhaustive plan-ownership scan
#   ./run_tlc.sh --mode          exhaustive session-mode preparation scan
#   ./run_tlc.sh --selection     exhaustive owned-selection scan
#   ./run_tlc.sh --approval      exhaustive captured-approval scan
#   ./run_tlc.sh --process       exhaustive process-capture scan
#   ./run_tlc.sh --diagnostics   exhaustive diagnostic-ownership scan
#   ./run_tlc.sh --debug-startup exhaustive debugger-startup ownership scan
#   ./run_tlc.sh --debug-watch   exhaustive debugger-watch ownership scan
#   ./run_tlc.sh --debug-execution exhaustive debugger-execution ownership scan
#   ./run_tlc.sh --verification  exhaustive changed-file ownership scan
#   ./run_tlc.sh --debug-selection exhaustive debugger-selection scan
#   ./run_tlc.sh --debug-readiness exhaustive debugger-readiness scan
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
        KARGU_TLC_COMMAND=(bash "${SCRIPT_DIR}/run_tlc.sh" "$@")
        printf -v KARGU_TLC_RUN '%q ' "${KARGU_TLC_COMMAND[@]}"
        exec nix-shell "${SCRIPT_DIR}/../shell.nix" --run \
            "${KARGU_TLC_RUN}"
    fi
    echo "ERROR: tlc (TLA+ model checker) not found in PATH and nix-shell unavailable." >&2
    exit 1
fi

METADIR="$(mktemp -d "${TMPDIR:-/tmp}/kargu-tlc.XXXXXX")"
LOG="${METADIR}/tlc.log"
trap 'rm -rf "${METADIR}"' EXIT

SPECIFICATION="MC.tla (KarguLoop, KarguProtocol, KarguCircuit, KarguTools, KarguState)"
if [[ $# -eq 0 ]]; then
    MODE="exhaustive scan"
    ARGS=(-workers auto -nowarning -metadir "${METADIR}" MC.tla)
elif [[ "$1" == "--mode" ]]; then
    MODE="exhaustive session-mode preparation scan"
    SPECIFICATION="ModeMC.tla (KarguMode)"
    ARGS=(-workers auto -nowarning -metadir "${METADIR}" -config ModeMC.cfg ModeMC.tla)
elif [[ "$1" == "--plan" ]]; then
    MODE="exhaustive plan-ownership scan"
    SPECIFICATION="PlanMC.tla (KarguPlan)"
    ARGS=(-workers auto -nowarning -metadir "${METADIR}" -config PlanMC.cfg PlanMC.tla)
elif [[ "$1" == "--approval" ]]; then
    MODE="exhaustive captured-approval scan"
    SPECIFICATION="ApprovalMC.tla (KarguApproval)"
    ARGS=(-workers auto -nowarning -metadir "${METADIR}" -config ApprovalMC.cfg ApprovalMC.tla)
elif [[ "$1" == "--selection" ]]; then
    MODE="exhaustive owned-selection scan"
    SPECIFICATION="SelectionMC.tla (KarguSelection)"
    ARGS=(-workers auto -nowarning -metadir "${METADIR}" -config SelectionMC.cfg SelectionMC.tla)
elif [[ "$1" == "--process" ]]; then
    MODE="exhaustive process-capture scan"
    SPECIFICATION="ProcessMC.tla (KarguProcess)"
    ARGS=(-workers auto -nowarning -metadir "${METADIR}" -config ProcessMC.cfg ProcessMC.tla)
elif [[ "$1" == "--diagnostics" ]]; then
    MODE="exhaustive diagnostic-ownership scan"
    SPECIFICATION="DiagnosticsMC.tla (KarguDiagnostics)"
    ARGS=(-workers auto -nowarning -metadir "${METADIR}" -config DiagnosticsMC.cfg DiagnosticsMC.tla)
elif [[ "$1" == "--debug-startup" ]]; then
    MODE="exhaustive debugger-startup ownership scan"
    SPECIFICATION="DebugStartupMC.tla (KarguDebugStartup)"
    ARGS=(-workers auto -nowarning -metadir "${METADIR}" -config DebugStartupMC.cfg DebugStartupMC.tla)
elif [[ "$1" == "--debug-watch" ]]; then
    MODE="exhaustive debugger-watch ownership scan"
    SPECIFICATION="DebugWatchMC.tla (KarguDebugWatch)"
    ARGS=(-workers auto -nowarning -metadir "${METADIR}" -config DebugWatchMC.cfg DebugWatchMC.tla)
elif [[ "$1" == "--debug-execution" ]]; then
    MODE="exhaustive debugger-execution ownership scan"
    SPECIFICATION="DebugExecutionMC.tla (KarguDebugExecution)"
    ARGS=(-workers auto -nowarning -metadir "${METADIR}" -config DebugExecutionMC.cfg DebugExecutionMC.tla)
elif [[ "$1" == "--verification" ]]; then
    MODE="exhaustive changed-file ownership scan"
    SPECIFICATION="VerificationMC.tla (KarguVerification)"
    ARGS=(-workers auto -nowarning -metadir "${METADIR}" -config VerificationMC.cfg VerificationMC.tla)
elif [[ "$1" == "--debug-selection" ]]; then
    MODE="exhaustive debugger-selection scan"
    SPECIFICATION="DebugSelectionMC.tla (KarguDebugSelection)"
    ARGS=(-workers auto -nowarning -metadir "${METADIR}" -config DebugSelectionMC.cfg DebugSelectionMC.tla)
elif [[ "$1" == "--debug-readiness" ]]; then
    MODE="exhaustive debugger-readiness scan"
    SPECIFICATION="DebugReadinessMC.tla (KarguDebugReadiness)"
    ARGS=(-workers auto -nowarning -metadir "${METADIR}" -config DebugReadinessMC.cfg DebugReadinessMC.tla)
elif [[ "$1" == "--simulate" ]]; then
    MODE="random simulation (not a proof)"
    ARGS=(-workers auto -nowarning -metadir "${METADIR}" -simulate "num=${2:-100000}" MC.tla)
else
    MODE="custom arguments"
    ARGS=("$@")
fi

echo "=== TLC on Kargu: ${MODE} ==="
echo "Specification: ${SPECIFICATION}"
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
