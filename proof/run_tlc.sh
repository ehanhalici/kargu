#!/usr/bin/env bash
# run_tlc.sh --- Execute TLC model checker for Kargu TLA+ specification
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

TLC_BIN="$(which tlc 2>/dev/null || true)"
if [[ -z "${TLC_BIN}" ]]; then
    echo "ERROR: tlc (TLA+ model checker) not found in PATH."
    exit 1
fi

echo "=== Running TLC Model Checker on Kargu Formal Specification ==="
echo "Specification: MC.tla (extends KarguLoop.tla, KarguProtocol.tla)"
echo "TLC Binary: ${TLC_BIN}"
echo "---------------------------------------------------------------"

"${TLC_BIN}" -workers auto -nowarning MC.tla

echo "---------------------------------------------------------------"
echo "TLC Model Checking Succeeded: All Protocol & Safety Invariants Verified!"
