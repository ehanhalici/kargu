#!/usr/bin/env bash
# run_tlc.sh --- Check the Kargu TLA+ specification with TLC.
#
#   ./run_tlc.sh                 exhaustive breadth-first scan (the proof)
#   ./run_tlc.sh --plan          exhaustive plan-ownership scan
#   ./run_tlc.sh --mode          exhaustive session-mode preparation scan
#   ./run_tlc.sh --application   exhaustive native claim/teardown scan
#   ./run_tlc.sh --budget        exhaustive run-budget scan
#   ./run_tlc.sh --restore       exhaustive prepared-restoration scan
#   ./run_tlc.sh --selection     exhaustive owned-selection scan
#   ./run_tlc.sh --approval      exhaustive captured-approval scan
#   ./run_tlc.sh --process       exhaustive process-capture scan
#   ./run_tlc.sh --process-session exhaustive interactive session scan
#   ./run_tlc.sh --diagnostics   exhaustive diagnostic-ownership scan
#   ./run_tlc.sh --debug-startup exhaustive debugger-startup ownership scan
#   ./run_tlc.sh --debug-close   exhaustive scoped-debugger shutdown scan
#   ./run_tlc.sh --debug-watch   exhaustive debugger-watch ownership scan
#   ./run_tlc.sh --debug-execution exhaustive debugger-execution ownership scan
#   ./run_tlc.sh --verification  exhaustive changed-file ownership scan
#   ./run_tlc.sh --edit-journal   exhaustive bounded journal/recovery scan
#   ./run_tlc.sh --edit-preparation exhaustive native proposal/Git drain scan
#   ./run_tlc.sh --edit-transaction exhaustive reviewed edit transaction scan
#   ./run_tlc.sh --debug-selection exhaustive debugger-selection scan
#   ./run_tlc.sh --debug-readiness exhaustive debugger-readiness scan
#   ./run_tlc.sh --connection    exhaustive connection-snapshot scan
#   ./run_tlc.sh --transport     exhaustive transport-contract scan
#   ./run_tlc.sh --dfid N [mode] exhaustive depth-first check; requires completion
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

DFID_DEPTH=""
if [[ "${1:-}" == "--dfid" ]]; then
    if [[ ! "${2:-}" =~ ^[0-9]+$ ]] || [[ ${#2} -gt 6 ]] || (( 10#$2 < 2 )); then
        echo "ERROR: --dfid requires an integer depth from 2 through 999999." >&2
        exit 1
    fi
    DFID_DEPTH="$2"
    shift 2
fi

SPECIFICATION="MC.tla (KarguLoop, KarguProtocol, KarguCircuit, KarguTools, KarguState)"
if [[ $# -eq 0 ]]; then
    MODE="exhaustive scan"
    ARGS=(-workers auto -nowarning -metadir "${METADIR}" MC.tla)
elif [[ "$1" == "--application" ]]; then
    MODE="exhaustive native claim/teardown scan"
    SPECIFICATION="ApplicationMC.tla (KarguApplication)"
    ARGS=(-workers auto -nowarning -metadir "${METADIR}" -config ApplicationMC.cfg ApplicationMC.tla)
elif [[ "$1" == "--restore" ]]; then
    MODE="exhaustive prepared-restoration scan"
    SPECIFICATION="RestoreMC.tla (KarguRestore)"
    ARGS=(-workers auto -nowarning -metadir "${METADIR}" -config RestoreMC.cfg RestoreMC.tla)
elif [[ "$1" == "--mode" ]]; then
    MODE="exhaustive session-mode preparation scan"
    SPECIFICATION="ModeMC.tla (KarguMode)"
    ARGS=(-workers auto -nowarning -metadir "${METADIR}" -config ModeMC.cfg ModeMC.tla)
elif [[ "$1" == "--budget" ]]; then
    MODE="exhaustive run-budget scan"
    SPECIFICATION="BudgetMC.tla (KarguBudget)"
    ARGS=(-workers auto -nowarning -metadir "${METADIR}" -config BudgetMC.cfg BudgetMC.tla)
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
elif [[ "$1" == "--process-session" ]]; then
    MODE="exhaustive interactive process-session scan"
    SPECIFICATION="ProcessSessionMC.tla (KarguProcessSession)"
    ARGS=(-workers auto -nowarning -metadir "${METADIR}" -config ProcessSessionMC.cfg ProcessSessionMC.tla)
elif [[ "$1" == "--diagnostics" ]]; then
    MODE="exhaustive diagnostic-ownership scan"
    SPECIFICATION="DiagnosticsMC.tla (KarguDiagnostics)"
    ARGS=(-workers auto -nowarning -metadir "${METADIR}" -config DiagnosticsMC.cfg DiagnosticsMC.tla)
elif [[ "$1" == "--debug-close" ]]; then
    MODE="exhaustive scoped-debugger shutdown scan"
    SPECIFICATION="DebugCloseMC.tla (KarguDebugClose)"
    ARGS=(-workers auto -nowarning -metadir "${METADIR}" -config DebugCloseMC.cfg DebugCloseMC.tla)
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
elif [[ "$1" == "--edit-journal" ]]; then
    MODE="exhaustive native edit journal scan"
    SPECIFICATION="EditJournalMC.tla (KarguEditJournal)"
    ARGS=(-workers auto -nowarning -metadir "${METADIR}" -config EditJournalMC.cfg EditJournalMC.tla)
elif [[ "$1" == "--edit-preparation" ]]; then
    MODE="exhaustive native edit preparation scan"
    SPECIFICATION="EditPreparationMC.tla (KarguEditPreparation)"
    ARGS=(-workers auto -nowarning -metadir "${METADIR}" -config EditPreparationMC.cfg EditPreparationMC.tla)
elif [[ "$1" == "--edit-transaction" ]]; then
    MODE="exhaustive reviewed edit transaction scan"
    SPECIFICATION="EditMC.tla (KarguEdit)"
    ARGS=(-workers auto -nowarning -metadir "${METADIR}" -config EditMC.cfg EditMC.tla)
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
elif [[ "$1" == "--connection" ]]; then
    MODE="exhaustive connection-snapshot scan"
    SPECIFICATION="ConnectionMC.tla (KarguConnection)"
    ARGS=(-workers auto -nowarning -metadir "${METADIR}" -config ConnectionMC.cfg ConnectionMC.tla)
elif [[ "$1" == "--transport" ]]; then
    MODE="exhaustive transport-contract scan"
    SPECIFICATION="TransportMC.tla (KarguTransport)"
    ARGS=(-workers auto -nowarning -metadir "${METADIR}" -config TransportMC.cfg TransportMC.tla)
elif [[ "$1" == "--simulate" ]]; then
    MODE="random simulation (not a proof)"
    ARGS=(-workers auto -nowarning -metadir "${METADIR}" -simulate "num=${2:-100000}" MC.tla)
else
    MODE="custom arguments"
    ARGS=("$@")
fi

if [[ -n "${DFID_DEPTH}" ]]; then
    for ((i=0; i<${#ARGS[@]}; i++)); do
        if [[ "${ARGS[i]}" == "-simulate" ]]; then
            echo "ERROR: --dfid is model checking and cannot be combined with simulation." >&2
            exit 1
        fi
        if [[ "${ARGS[i]}" == "-workers" ]]; then
            ARGS[i+1]=1
        fi
    done
    ARGS=(-dfid "${DFID_DEPTH}" "${ARGS[@]}")
    MODE="exhaustive depth-first scan (${MODE}); requires a completed verdict"
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
if [[ "${MODE}" == "random simulation (not a proof)" ]]; then
    if ! grep -q "Finished in" "${LOG}"; then
        echo "TLC simulation did not finish." >&2
        exit 1
    fi
elif ! grep -qF "Model checking completed. No error has been found." "${LOG}"; then
    echo "TLC did not complete exhaustive exploration: no proof verdict." >&2
    exit 1
fi
echo "TLC finished without error (${MODE})."
