#!/usr/bin/env python3
"""Lint changed Elisp and the independent bridge without writing checkout bytecode."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
os.chdir(ROOT)
base = sys.argv[1]
changed = subprocess.check_output(
    ["git", "diff", "--name-only", "-z", "--diff-filter=ACMR", base, "HEAD", "--", "*.el"]
).decode().split("\0")
files = sorted(set(filter(None, changed)) | {
    "kargu/bridge.el", "kargu/bridge/approval.el", "kargu/bridge/jobs.el",
    "kargu/bridge/job-output.el", "tests/test-bridge.el", "tests/test-bridge-jobs.el",
})
with tempfile.TemporaryDirectory(prefix="kargu-ci-lint-") as home:
    subprocess.run([
        "emacs", "--batch", "-Q", "-L", ".",
        "-L", os.environ["KARGU_CI_COMPANY_DIR"],
        "-L", os.environ["KARGU_CI_DAPE_DIR"],
        "-l", "tests/ci/lint-elisp.el", "--", *files,
    ], check=True, env={
        "PATH": os.environ["PATH"], "LANG": "C.UTF-8", "HOME": home,
        "XDG_CONFIG_HOME": str(Path(home) / "config"),
    })
