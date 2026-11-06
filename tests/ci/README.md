# Offline source checks

Build `kargu-core` from the checkout before running ERT. Supply explicit fixture
package directories; the full gate requires Company and Dape 0.27.1. CI installs
Company and checks out Dape at the commit pinned in the workflow. These tests use
synthetic protocol replies, temporary projects and loopback HTTP, without real
accounts or a live debugger/server.

```sh
export KARGU_CORE_TEST_BINARY="$PWD/kargu-core/target/debug/kargu-core"
export KARGU_CI_COMPANY_DIR=/path/to/company
export KARGU_CI_DAPE_DIR=/path/to/dape

tests/ci/run-ert.sh bridge
tests/ci/run-ert.sh full
python3 tests/ci/check-elisp.py BASE_COMMIT
python3 tests/ci/test-select-models.py
python3 tests/ci/select-models.py BASE_COMMIT
```

ERT runs with an empty temporary HOME/config and no inherited credentials. It
rejects checkout bytecode and skipped tests. Elisp lint uses a temporary HOME,
writes bytecode outside the checkout, and treats compiler/checkdoc findings as
failures. The independent bridge is always compiled; other Elisp files are
selected from the committed diff against BASE_COMMIT.

Model selection follows local EXTENDS and INSTANCE dependencies to configured
roots. Documentation/script-only changes select nothing. Unmapped source edits
fail the gate. The selector tests use a fake executable to check runner arguments;
they do not perform model checking. CI only provisions Nix and invokes the actual
TLC runner when `.tla` or `.cfg` sources changed. Headless results do not establish
GUI or live backend acceptance.
