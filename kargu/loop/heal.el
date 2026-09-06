;;; kargu/loop/heal.el --- Post-edit LSP diagnostics -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; After an applied edit, wait for diagnostics and append them
;; inside the tool result (protocol-safe).

;;; Code:

(require 'cl-lib)
;; Ensure the package root is on `load-path' during byte/native
;; compilation from a subdirectory (Magit-style kargu/core features).
(eval-and-compile
  (let ((root (locate-dominating-file
               (or (bound-and-true-p byte-compile-current-file)
                   load-file-name
                   buffer-file-name
                   default-directory)
               "kargu.el")))
    (when root
      (add-to-list 'load-path (file-name-as-directory
                               (expand-file-name root))))))

(require 'kargu/core)
(require 'kargu/tools/diff)
(require 'kargu/tools/lsp)

(defvar kargu-max-healing-steps)
(declare-function kargu-loop--live-p "kargu/loop" (run))
(declare-function kargu-loop--set-state "kargu/loop" (run state))
(declare-function kargu--loop-add-result-and-continue "kargu/loop/tools"
                 (run id name result queue))

(defun kargu--loop-verify-files (run id name result queue files)
  "Collect settling diagnostics for FILES, then finish the result."
  (kargu-loop--set-state run 'verify)
  (kargu--loop-verify-next run id name result queue files nil))

(defun kargu--loop-verify-next (run id name result queue pending done)
  "Verify the next file in PENDING; DONE collects finished sections."
  (cond
   ((not (kargu-loop--live-p run)) nil)
   ((null pending)
    (let* ((sections (nreverse done))
           (errors (kargu--loop-count-section-errors sections))
           (healing (or (plist-get run :healing) 0)))
      (when (> errors 0)
        (plist-put run :healing (1+ healing)))
      (kargu-log 'info "loop: verification done, %d error(s)" errors)
      (kargu--loop-add-result-and-continue
       run id name
       (kargu--loop-compose-verified result sections errors healing)
       queue)))
   (t
    (let ((file (car pending)))
      (kargu-lsp-wait-diagnostics
       file
       (lambda (path text _timeout-p)
         (when (kargu-loop--live-p run)
           (kargu-diff-consume-file path)
           (kargu-log 'info "loop: diagnostics settled for %s" path)
           (kargu--loop-verify-next
            run id name result queue (cdr pending)
            (cons (kargu--loop-diag-section path text) done)))))))))

(defun kargu--loop-diag-section (path text)
  "Build one diagnostics section plist for PATH and its TEXT."
  (list :path path
        :text text
        :errors (kargu--loop-count-errors path text)))

(defun kargu--loop-count-errors (path text)
  "Count error-severity diagnostics for PATH."
  (let ((count 0))
    (dolist (diag (kargu-lsp--diagnostics-data path))
      (when (eq (plist-get diag :severity) 1)
        (setq count (1+ count))))
    (if (> count 0)
        count
      (let ((start 0) (n 0))
        (while (string-match "\\[error\\]" text start)
          (setq n (1+ n)
                start (match-end 0)))
        n))))

(defun kargu--loop-count-section-errors (sections)
  "Sum the :errors counts of SECTIONS."
  (let ((total 0))
    (dolist (section sections)
      (setq total (+ total (or (plist-get section :errors) 0))))
    total))

(defun kargu--loop-compose-verified (result sections errors healing)
  "Combine the tool RESULT with diagnostics SECTIONS."
  (concat
   result
   "\n\n--- Verification after edit ("
   (if (zerop errors) "clean" (format "%d error(s)" errors))
   ") [Flycheck / LSP] ---\n"
   (mapconcat (lambda (section) (plist-get section :text)) sections "\n")
   (if (zerop errors)
       "\n\nVerification passed: the edited file reports no errors (Flycheck & LSP clean)."
     (format
      "\n\nSELF-HEALING (round %d of %d): the edited file reports %d error(s) above (Flycheck / LSP).  Fix them now with a corrected edit_file (unique old_string / new_string), or explain why they are pre-existing."
      (1+ healing) kargu-max-healing-steps errors))))

(provide 'kargu/loop/heal)

;;; kargu/loop/heal.el ends here
