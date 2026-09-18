;;; kargu/languages/python.el --- Python language profile for Kargu -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Code:

(require 'kargu/languages/core)

(defconst kargu-language-python-spec
  (kargu-make-language-spec
   :id 'python
   :name "Python"
   :priority 80
   :extensions '("py" "pyi")
   :detectors '("pyproject.toml" "setup.py" "setup.cfg" "requirements.txt" "Pipfile")
   :toolchain
   '(:build-cmd "python -m py_compile <file>"
     :test-cmd "pytest || python -m unittest discover"
     :lint-cmd "ruff check || mypy ."
     :notes "Run tests using `pytest` via `bash`. Check typing with `mypy` or `ruff`.")
   :debugger
   '(:adapter "debugpy"
     :supports-eval t
     :supports-method-calls t
     :eval-guidance
     "Full dynamic evaluation: any valid Python expression in the current frame (variables, attributes, method and function calls, slicing, comprehensions) can be evaluated."
     :variable-inspection-advice
     "Inspect locals and globals via `debug_get_context` or `debug_scope`. Tracebacks and active exceptions are highlighted upon pausing."
     :common-eval-pitfalls
     '(("NameError: name '.*' is not defined" .
        "Variable is not defined in the current frame. Check `debug_scope` for available local/global variables.")
       ("AttributeError:" .
        "Attribute does not exist on the object. Evaluate `dir(obj)` or inspect the object structure in `debug_scope`.")))
   :lsp-notes
   "Python symbols: functions (def), classes (class), async functions, methods. Pyright/Basedpyright provides precise symbol outlines."))

(kargu-language-register kargu-language-python-spec)

(provide 'kargu/languages/python)

;;; kargu/languages/python.el ends here
