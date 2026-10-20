;;; register.el --- LSP tool registration -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Expose symbol and diagnostic operations through the tool registry.

;;; Code:

(require 'kargu/api/tools)
(require 'kargu/tools/lsp/skeleton)
(require 'kargu/tools/lsp/diagnostics)
(require 'kargu/tools/lsp/symbols)

;;;; Tool registration ----------------------------------------------------

(defconst kargu-lsp--tool-specs
  (list
   (list
    "lsp_project_skeleton"
    "Get a compact map of the whole project: every file with its symbols (functions, types, classes, constants) and line numbers. Use this FIRST to orient yourself; it is far cheaper than reading files."
    '(("type" . "object")
      ("properties" . :json-empty-object))
    (lambda (_args &optional callback) (kargu-lsp-build-skeleton nil callback)))
   (list
    "lsp_diagnostics"
    "Get compiler and linter diagnostics (errors, warnings) from LSP via Flymake. Pass 'file_path' to inspect a specific file, or OMIT 'file_path' (pass empty or no arguments) to scan the ENTIRE PROJECT for all compile and lint errors across all project files. Always call this after editing or building to verify zero compilation errors."
    '(("type" . "object")
      ("properties" . (("file_path" . (("type" . "string")
                                       ("description" . "Optional. Absolute or project-relative path of a specific file to check. When omitted or empty, runs a project-wide diagnostic scan across all project files."))))))
    (lambda (args)
      (let ((path (kargu--tool-file-path args)))
        (if (and path (not (string-empty-p (string-trim path))))
            (kargu-lsp-get-diagnostics path)
          (kargu-lsp-get-project-diagnostics)))))
   (list
    "lsp_find_symbol"
    "Locate where a named symbol (function, type, variable) is defined in the workspace. Returns file:line for each definition candidate."
    '(("type" . "object")
      ("properties" . (("symbol_name" . (("type" . "string")
                                         ("description" . "Name of the symbol to look up, e.g. the function or type name.")))))
      ("required" . ["symbol_name"]))
    (lambda (args &optional callback)
      (let ((name (kargu--tool-arg args "symbol_name" "symbolName" "symbol")))
        (if (or (null name) (string-empty-p name))
            "ERROR: symbol_name is required"
          (kargu-lsp-find-definition name callback)))))
   (list
    "read_file_symbols"
    "Get symbols and line ranges from LSP documentSymbol or native Emacs Lisp imenu. Use this before reading a large file to inspect its structure."
    '(("type" . "object")
      ("properties" . (("file_path" . (("type" . "string")
                                       ("description" . "Absolute or project-relative path of the file to inspect."))))))
    (lambda (args &optional callback)
      (let ((path (kargu--tool-file-path args)))
        (if (not (kargu-nonempty path))
            (kargu--tool-missing-file-path args)
          (condition-case-unless-debug err
              (kargu-lsp-read-file-symbols path callback)
            (error (format "ERROR: %s" (error-message-string err))))))))
   (list
    "read_symbol"
    "Read the exact implementation body of a specific symbol (function, method, class, struct, type) by name from a file. Uses LSP/imenu line ranges to fetch only the relevant code without loading the full file."
    '(("type" . "object")
      ("properties" . (("file_path" . (("type" . "string")
                                       ("description" . "Absolute or project-relative path of the file.")))
                       ("symbol" . (("type" . "string")
                                    ("description" . "Name of the symbol (function, method, class, struct, type) to read.")))
                       ("kind" . (("type" . "string")
                                  ("description" . "Optional symbol kind filter (e.g. Function, Method, Class, Struct, Type).")))))
      ("required" . ["file_path" "symbol"]))
    (lambda (args &optional callback)
      (let ((path (kargu--tool-file-path args))
            (sym (kargu--tool-arg args "symbol" "symbol_name" "symbolName" "name"))
            (kind (kargu--tool-arg args "kind" "symbol_kind" "symbolKind")))
        (cond
         ((not (kargu-nonempty path))
          (kargu--tool-missing-file-path args))
         ((or (null sym) (string-empty-p (string-trim sym)))
          "ERROR: symbol is required")
         (t
          (condition-case-unless-debug err
              (kargu-lsp-read-symbol path sym kind callback)
            (error (format "ERROR: %s" (error-message-string err)))))))))
   (list
    "edit_by_lsp"
    "Replace the entire implementation body or definition of a specific symbol (function, method, class, struct, type) in a source file with new content. Uses exact language-agnostic LSP/imenu symbol line boundaries. ALWAYS PREFER THIS over edit_file for modifying existing code definitions across all programming languages."
    '(("type" . "object")
      ("properties" . (("file_path" . (("type" . "string")
                                       ("description" . "Absolute or project-relative path of the file to edit.")))
                       ("symbol" . (("type" . "string")
                                    ("description" . "Name of the symbol (function, method, class, struct, type) to replace.")))
                       ("new_content" . (("type" . "string")
                                         ("description" . "New code to replace the entire symbol body/definition with (use empty string to delete).")))
                       ("kind" . (("type" . "string")
                                  ("description" . "Optional symbol kind filter (e.g. Function, Method, Class, Struct, Type).")))
                       ("reason" . (("type" . "string")
                                    ("description" . "Optional explanation for the change.")))))
      ("required" . ["file_path" "symbol" "new_content"]))
    (lambda (args &optional callback)
      (let ((path (kargu--tool-file-path args))
            (sym (kargu--tool-arg args "symbol" "symbol_name" "symbolName" "name"))
            (new (kargu--tool-arg-string args "new_content" "newContent" "content" "new_string" "newString" "code"))
            (kind (kargu--tool-arg args "kind" "symbol_kind" "symbolKind"))
            (reason (kargu--tool-arg args "reason")))
        (cond
         ((not (kargu-nonempty path))
          (kargu--tool-missing-file-path args))
         ((or (null sym) (string-empty-p (string-trim sym)))
          "ERROR: symbol is required")
         ((null new)
          "ERROR: new_content is required")
         (t
          (condition-case-unless-debug err
              (kargu-lsp-edit-symbol path sym new kind reason callback)
            (error (format "ERROR: %s" (error-message-string err))))))))))
  "Tool schemas and executors exposed by the LSP adapter.")

(defconst kargu-lsp--tool-aliases
  '(("edit_symbol" . "edit_by_lsp")
    ("edit_with_lsp" . "edit_by_lsp")
    ("edit_by_symbol" . "edit_by_lsp")
    ("read_file_outline" . "read_file_symbols")
    ("file_symbols" . "read_file_symbols")
    ("outline" . "read_file_symbols")
    ("file_outline" . "read_file_symbols")
    ("get_symbol" . "read_symbol")
    ("symbol_body" . "read_symbol")
    ("read_symbol_body" . "read_symbol"))
  "Aliases for the LSP adapter tools.")

(defun kargu-lsp-register-tools ()
  "Register the LSP tools and their aliases."
  (kargu-register-tools
   kargu-lsp--tool-specs kargu-lsp--tool-aliases
   '(:available-p kargu-lsp-unavailable-reason))
  (dolist (name '("lsp_find_symbol" "read_file_symbols" "read_symbol"))
    (kargu-set-tool-policy name '(:available-p kargu-lsp-symbols-unavailable-reason)))
  (kargu-set-tool-policy
   "edit_by_lsp" '(:modes (agent) :available-p kargu-lsp-symbols-unavailable-reason)))

(provide 'kargu/tools/lsp/register)

;;; register.el ends here
