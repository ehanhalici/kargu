;;; project-probe.el --- Owned native toolchain observations -*- lexical-binding: t; -*-
;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Declarative editor profiles and package capabilities cross a bounded port.
;; Rust owns filesystem/executable discovery and file-dependent command choices.
;;; Code:
(require 'cl-lib)
(require 'kargu/bridge/read)
(require 'kargu/fs)
(require 'kargu/contract/result)
(require 'kargu/permission)
(defvar kargu-deps-mandatory-executables)
(defvar kargu-deps-lsp-server-overrides)
(defvar eglot-server-programs)
(defvar kargu-chat--project-root)
(defvar kargu-permission--override-root)
(defvar-local kargu-project-probe--view nil "Last completed observation for this buffer/session.")
(defvar-local kargu-project-probe--intent nil "Most recently admitted refresh identity.")
(declare-function kargu-language-list "kargu/languages/core" ())
(declare-function kargu-language-spec-id "kargu/languages/core" (spec))
(declare-function kargu-language-spec-name "kargu/languages/core" (spec))
(declare-function kargu-language-spec-priority "kargu/languages/core" (spec))
(declare-function kargu-language-spec-detectors "kargu/languages/core" (spec))
(declare-function kargu-language-spec-toolchain "kargu/languages/core" (spec))
(declare-function kargu-language-spec-lsp "kargu/languages/core" (spec))

(defun kargu-project-probe--condition (value)
  "Encode declarative detector VALUE without executing editor functions."
  (cond ((stringp value) (kargu-bridge--object "kind" "path" "path" value))
        ((memq (car-safe value) '(:any :all))
         (kargu-bridge--object "kind" (if (eq (car value) :any) "any" "all")
                               "items" (vconcat (mapcar #'kargu-project-probe--condition (cdr value)))))
        ((memq (car-safe value) '(:extension :root-extension))
         (kargu-bridge--object "kind" "extension" "extensions" (vconcat (cdr value))
                               "recursive" (if (eq (car value) :extension) t :json-false)))
        (t (error "Native detectors require path strings or :any/:all/:extension/:root-extension forms"))))

(defun kargu-project-probe--commands (plist)
  "Encode static command metadata PLIST; no command is executed."
  (let ((object (kargu-bridge--object)))
    (dolist (pair '((:build-cmd . "build_cmd") (:test-cmd . "test_cmd") (:lint-cmd . "lint_cmd") (:notes . "notes")))
      (puthash (cdr pair) (or (plist-get plist (car pair)) :json-null) object)) object))

(defvar kargu-toolchain-strategies)
(declare-function kargu-toolchain-strategy-name "kargu/tools/toolchain" (strategy))
(declare-function kargu-toolchain-strategy-priority "kargu/tools/toolchain" (strategy))
(declare-function kargu-toolchain-strategy-detector "kargu/tools/toolchain" (strategy))
(declare-function kargu-toolchain-strategy-resolver "kargu/tools/toolchain" (strategy))

(defun kargu-project-probe--profile (id name priority detectors tc &optional fallback)
  "Encode ID/NAME/PRIORITY, DETECTORS and TC with optional FALLBACK ordering."
  (when (functionp tc) (error "Callable toolchains require declarative command metadata"))
  (let* ((native (plist-get tc :native))
         (toolchain (if native (kargu-bridge--object "kind" native)
                      (kargu-bridge--object "kind" "static" "commands" (kargu-project-probe--commands tc)))))
    (when (equal native "javascript") (puthash "typescript" (if (equal id "typescript") t :json-false) toolchain))
    (kargu-bridge--object "id" id "name" name "priority" (or priority 0)
                          "fallback" (if fallback t :json-false)
                          "detectors" (vconcat (mapcar #'kargu-project-probe--condition detectors))
                          "toolchain" toolchain)))

(defun kargu-project-probe--profiles ()
  "Capture registered language and fallback strategy metadata for Rust."
  (vconcat
   (mapcar (lambda (spec)
             (kargu-project-probe--profile
              (symbol-name (kargu-language-spec-id spec)) (kargu-language-spec-name spec)
              (kargu-language-spec-priority spec) (kargu-language-spec-detectors spec)
              (kargu-language-spec-toolchain spec))) (kargu-language-list))
   (mapcar (lambda (strategy)
             (let ((name (format "%s" (kargu-toolchain-strategy-name strategy))))
               (kargu-project-probe--profile
                (concat "strategy-" name) name (kargu-toolchain-strategy-priority strategy)
                (list (kargu-toolchain-strategy-detector strategy))
                (kargu-toolchain-strategy-resolver strategy) t)))
           (bound-and-true-p kargu-toolchain-strategies))))

(defun kargu-project-probe--executables ()
  "Capture configured CLI names; package and live Eglot facts stay in Emacs."
  (let ((names (append '("fd" "fdfind" "rg" "grep" "git")
                       (copy-sequence (bound-and-true-p kargu-deps-mandatory-executables)))))
    (dolist (spec (kargu-language-list))
      (setq names (append (plist-get (kargu-language-spec-lsp spec) :binaries) names)))
    (dolist (entry (bound-and-true-p kargu-deps-lsp-server-overrides))
      (setq names (append (plist-get (cdr entry) :binaries) names)))
    (dolist (entry (bound-and-true-p eglot-server-programs))
      (let ((contact (cdr entry)))
        (when (stringp (if (listp contact) (car contact) contact))
          (push (if (listp contact) (car contact) contact) names))))
    (vconcat (delete-dups names))))

(defun kargu-project-probe--arguments (root)
  "Capture ROOT and bounded metadata without probing files or executables."
  (kargu-bridge--object
   "root" (file-name-as-directory (expand-file-name root)) "profiles" (kargu-project-probe--profiles)
   "executables" (kargu-project-probe--executables)
   "search_path" (vconcat (mapcar (lambda (p) (expand-file-name (or p root))) exec-path))
   "skip_directories" (vconcat kargu-fs-skip-dirs) "max_files" kargu-fs-max-listed-files
   "max_directories" kargu-fs-max-visited-directories))

(defun kargu-project-probe--signature (arguments)
  "Return a detached, bounded wire identity for ARGUMENTS."
  (json-serialize arguments :null-object :json-null :false-object :json-false))

(defun kargu-project-probe--copy (value)
  "Detach bounded native JSON VALUE from an observer."
  (json-parse-string (kargu-project-probe--signature value) :object-type 'hash-table
                     :array-type 'array :null-object :json-null :false-object :json-false))

(defun kargu-project-probe--origin-key ()
  "Capture memory-backed source identity without a filesystem probe."
  (mapcar (lambda (v) (if (stringp v) (file-name-as-directory (expand-file-name v)) v))
          (list default-directory kargu-permission--override-root (bound-and-true-p kargu-chat--project-root))))

(defun kargu-project-probe-refresh (callback &optional root)
  "Refresh ROOT's native project/CLI facts and deliver a Result to CALLBACK."
  (let* ((root (or root (kargu-permission-project-root)))
         (arguments (kargu-project-probe--arguments root))
         (signature (kargu-project-probe--signature arguments))
         (session (kargu-session-context)) (intent (list nil))
         (origin-key (kargu-project-probe--origin-key))
         (parent kargu-async--current-task))
    (when (and (or (null kargu-execution--current) (kargu-execution-live-p kargu-execution--current))
               (or (null parent) (and (kargu-async-pending-p parent)
                                (or (null (kargu-async-task-deadline parent)) (> (kargu-async-task-deadline parent) (float-time))))))
      (setq kargu-project-probe--intent intent))
    (kargu-bridge-read-task
     (lambda (value)
       (cond
        ((stringp value) (funcall callback (kargu-err value :probe-unavailable)))
        ((not (and (eq intent kargu-project-probe--intent) (eq session (kargu-session-context))
                   (equal origin-key (kargu-project-probe--origin-key))
                   (equal signature (kargu-project-probe--signature (kargu-project-probe--arguments root)))))
         (funcall callback (kargu-err "Native probe inputs changed" :stale)))
        (t (setq kargu-project-probe--view (list :root (gethash "root" arguments) :session session :origin-key origin-key :signature signature :value (kargu-project-probe--copy value)))
           (funcall callback (kargu-ok value)))))
     arguments #'kargu-bridge-probe
     (lambda (value)
       (unless (and (hash-table-p (gethash "toolchains" value)) (hash-table-p (gethash "executables" value))
                    (memq (gethash "complete" value) '(t :json-false))) (error "Invalid native project observation"))
       value))))

(defun kargu-project-probe-view (&optional root)
  "Return the matching completed ROOT observation without filesystem or IPC."
  (let ((view kargu-project-probe--view))
    (when (and view (eq (plist-get view :session) (kargu-session-context))
               (equal (plist-get view :origin-key) (kargu-project-probe--origin-key))
               (equal (plist-get view :signature)
                      (kargu-project-probe--signature (kargu-project-probe--arguments (or root (plist-get view :root))))))
      (kargu-project-probe--copy (plist-get view :value)))))

(defun kargu-project-probe-toolchain (id root)
  "Return detached command metadata for profile ID under observed ROOT."
  (when-let* ((view (kargu-project-probe-view root)) ((eq (gethash "complete" view) t))
              (commands (gethash (if (symbolp id) (symbol-name id) id) (gethash "toolchains" view))))
    (let (result)
      (dolist (pair '((:build-cmd . "build_cmd") (:test-cmd . "test_cmd") (:lint-cmd . "lint_cmd") (:notes . "notes")))
        (when-let* ((text (gethash (cdr pair) commands)) ((stringp text)))
          (setq result (plist-put result (car pair) (copy-sequence text))))) result)))

(provide 'kargu/project-probe)
;;; project-probe.el ends here
