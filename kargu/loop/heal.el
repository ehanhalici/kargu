;;; heal.el --- Post-edit LSP diagnostics -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; After an applied edit, wait for diagnostics and append them
;; inside the tool result (protocol-safe).

;;; Code:

(require 'cl-lib)
(require 'kargu/core)
(require 'kargu/tools/diff)
(require 'kargu/tools/lsp)

(defvar kargu-max-healing-steps)
(declare-function kargu-loop--live-p "kargu/loop" (run))
(declare-function kargu-loop--set-state "kargu/loop" (run state))
(declare-function kargu--loop-add-result-and-continue "kargu/loop/tools"
                  (run id name result queue))

(defun kargu--loop-verify-files (run id name result queue files)
  "Collect FILES diagnostics for ID and NAME on RUN after RESULT, then QUEUE."
  (kargu-loop--set-state run 'verify)
  (kargu--loop-verify-next run id name result queue files nil))

(defun kargu--loop-verify-next (run id name result queue pending done)
  "Verify PENDING for ID and NAME on RUN after RESULT; DONE precedes QUEUE."
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
       (lambda (path text timeout-p)
         (when (kargu-loop--live-p run)
           (kargu-diff-consume-file path)
           (kargu-log 'info "loop: diagnostics %s for %s"
                      (if timeout-p "timed out" "settled") path)
           (kargu--loop-verify-next
            run id name result queue (cdr pending)
            (cons (kargu--loop-diag-section path text timeout-p) done)))))))))

(defun kargu--loop-diag-section (path text timeout-p)
  "Build one diagnostics section plist for PATH and its TEXT.
TIMEOUT-P means the snapshot was not settled."
  (list :path path
        :text (if timeout-p
                  (concat (or text "")
                          "\n(diagnostics did not settle before the timeout)")
                (or text "(diagnostics unavailable)"))
        :unavailable (null text)
        :errors (kargu--loop-count-errors path text)
        :timeout (and timeout-p t)))

(defun kargu--loop-sections-timed-out-p (sections)
  "Non-nil when any section in SECTIONS timed out."
  (cl-some (lambda (section) (plist-get section :timeout)) sections))

(defun kargu--loop-count-errors (path text)
  "Count error-severity diagnostics for PATH using structured data or TEXT."
  (let ((count 0) (text (or text "")))
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

(defun kargu--loop-verify-headline (sections errors)
  "Status word for SECTIONS given ERRORS."
  (cond
   ((> errors 0) (format "%d error(s)" errors))
   ((seq-some (lambda (section) (plist-get section :unavailable)) sections)
    "diagnostics unavailable")
   ((kargu--loop-sections-timed-out-p sections) "diagnostics timed out")
   (t "clean")))

(defun kargu--loop-verify-footer (sections errors healing)
  "Return a closing paragraph for SECTIONS with ERRORS and HEALING."
  (cond
   ((> errors 0)
    (format "\n\nSELF-HEALING (round %d of %d): the edited file reports %d error(s) above (Flymake / LSP).  Fix them now with a corrected edit_file (unique old_string / new_string), or explain why they are pre-existing."
            (1+ healing) kargu-max-healing-steps errors))
   ((seq-some (lambda (section) (plist-get section :unavailable)) sections)
    "\n\nVerification incomplete: diagnostics are unavailable. Do not treat this edit as clean.")
   ((kargu--loop-sections-timed-out-p sections)
    "\n\nVerification incomplete: diagnostics timed out before a settled snapshot. Do not treat this edit as clean.")
   (t
    "\n\nVerification passed: the edited file reports no errors (Flymake & LSP clean).")))

(defun kargu--loop-compose-verified (result sections errors healing)
  "Combine RESULT with SECTIONS, ERRORS and the current HEALING count."
  (concat
   result
   "\n\n--- Verification after edit ("
   (kargu--loop-verify-headline sections errors)
   ") [Flymake / LSP] ---\n"
   (mapconcat (lambda (section) (plist-get section :text)) sections "\n")
   (kargu--loop-verify-footer sections errors healing)))

(provide 'kargu/loop/heal)

;;; heal.el ends here
