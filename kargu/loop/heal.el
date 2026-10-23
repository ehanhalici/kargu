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
(require 'kargu/edit)
(require 'kargu/async)

(declare-function kargu-lsp-wait-diagnostics "kargu/tools/lsp/settle"
                  (file-path callback &optional timeout))
(declare-function kargu-lsp-diagnostics-snapshot "kargu/tools/lsp/diagnostics"
                  (file-path))

(defun kargu-loop--wait-diagnostics (path callback)
  "Ask the diagnostic adapter about PATH, or deliver unavailable to CALLBACK."
  (if (fboundp 'kargu-lsp-wait-diagnostics)
      (kargu-lsp-wait-diagnostics path callback)
    (funcall callback path nil nil)))

(defvar kargu-max-healing-steps)
(declare-function kargu-loop--live-p "kargu/loop" (run))
(declare-function kargu-loop--set-state "kargu/loop" (run state))
(declare-function kargu--loop-add-result-and-continue "kargu/loop/tools"
                  (run id name result queue))

(cl-defstruct (kargu--verification (:constructor kargu--make-verification))
  "One verification batch with a task owning its pending edit records."
  run id name result queue pending baselines done task)

(defun kargu--loop-verify-files (run id name result queue files)
  "Collect FILES diagnostics for ID and NAME on RUN after RESULT, then QUEUE.
This entry point retains the after-tool dispatcher's positional signature."
  (when (kargu-loop--live-p run)
    (let* ((changes nil)
           (baselines nil)
           (_ (dolist (file files)
                (when-let* ((ch (kargu-edit-changes :capture file)))
                  (push ch changes)
                  (push (cons file (kargu-edit-changes :baseline ch)) baselines))))
           (changes (nreverse changes))
           (verification (kargu--make-verification
                          :run run :id id :name name :result result :queue queue
                          :pending files :baselines baselines))
           (task (kargu-async-start
                  (lambda (sections error)
                    (kargu--loop-publish-verification verification sections error))
                  :cancel (lambda ()
                            (mapc (lambda (change)
                                    (kargu-edit-changes :consume change)) changes)))))
      (setf (kargu--verification-task verification) task)
      (funcall (kargu-async-wrap
                task (lambda ()
                       (kargu-loop--set-state run 'verify)
                       (kargu--loop-verify-next verification))))
      task)))

(defun kargu--loop-publish-verification (verification sections error)
  "Publish SECTIONS or ERROR only for VERIFICATION's still-live run."
  (let ((run (kargu--verification-run verification)))
    (when (kargu-loop--live-p run)
      (when error
        (setq sections
              (nreverse (cons (list :text (format "(diagnostics unavailable: %s)" error)
                                    :unavailable t :errors 0 :new-errors 0)
                              (copy-sequence (kargu--verification-done verification))))))
      (let ((errors (kargu--loop-count-section-errors sections))
            (new-errors (kargu--loop-count-section-new-errors sections))
            (healing (or (plist-get run :healing) 0)))
        (when (> new-errors 0) (plist-put run :healing (1+ healing)))
        (kargu-log 'info "loop: verification done, %d error(s) (%d new)" errors new-errors)
        (kargu--loop-add-result-and-continue
         run (kargu--verification-id verification) (kargu--verification-name verification)
         (kargu--loop-compose-verified (kargu--verification-result verification) sections errors healing)
         (kargu--verification-queue verification))))))

(defun kargu--loop-verify-next (verification)
  "Collect the next file for VERIFICATION without consuming a newer edit."
  (let ((run (kargu--verification-run verification))
        (task (kargu--verification-task verification))
        (pending (kargu--verification-pending verification)))
    (cond
     ((not (kargu-loop--live-p run)) nil)
     ((null pending)
      (kargu-async-finish task (reverse (kargu--verification-done verification))))
     (t
      (let* ((target (car pending))
             (baseline (cdr (assoc target (kargu--verification-baselines verification)))))
        (kargu-loop--wait-diagnostics
         target
         (kargu-async-wrap
          task (lambda (path text timeout-p)
                 (when (and (kargu-loop--live-p run)
                            (eq pending (kargu--verification-pending verification)))
                   (kargu-log 'info "loop: diagnostics %s for %s"
                              (if timeout-p "timed out" "settled") path)
                   (push (kargu--loop-diag-section path text timeout-p baseline)
                         (kargu--verification-done verification))
                   (setf (kargu--verification-pending verification) (cdr pending))
                   (kargu--loop-verify-next verification))))))))))

(defun kargu--loop-diag-key (diag)
  "Return position-independent semantic key for diagnostic plist DIAG."
  (list (plist-get diag :severity)
        (plist-get diag :source)
        (plist-get diag :code)
        (plist-get diag :message)))

(defun kargu--loop-compare-diagnostics (baseline path total-errors timeout-p text)
  "Compare BASELINE against settled diagnostics for PATH with TOTAL-ERRORS.
TIMEOUT-P or missing TEXT prevents a verified delta.
Return (:baseline-available BOOL :new-errors INT :pre-existing-errors INT
:resolved-errors INT)."
  (if (or timeout-p (null text) (null baseline)
          (not (plist-get baseline :available))
          (not (fboundp 'kargu-lsp-diagnostics-snapshot)))
      (list :baseline-available nil
            :new-errors 0 :unclassified-errors total-errors
            :pre-existing-errors 0
            :resolved-errors 0)
    (let* ((base-errs (seq-filter (lambda (d) (eq (plist-get d :severity) 1))
                                  (plist-get baseline :diagnostics)))
           (post-errs (seq-filter (lambda (d) (eq (plist-get d :severity) 1))
                                  (kargu-lsp-diagnostics-snapshot path)))
           (pool (make-hash-table :test #'equal))
           (new-count 0)
           (pre-existing-count 0)
           (resolved-count 0))
      (dolist (d base-errs)
        (let ((k (kargu--loop-diag-key d)))
          (puthash k (1+ (gethash k pool 0)) pool)))
      (dolist (d post-errs)
        (let* ((k (kargu--loop-diag-key d))
               (rem (gethash k pool 0)))
          (if (> rem 0)
              (progn
                (puthash k (1- rem) pool)
                (setq pre-existing-count (1+ pre-existing-count)))
            (setq new-count (1+ new-count)))))
      (maphash (lambda (_k rem) (setq resolved-count (+ resolved-count rem))) pool)
      (list :baseline-available t
            :new-errors new-count
            :pre-existing-errors pre-existing-count
            :resolved-errors resolved-count))))

(defun kargu--loop-diag-section (path text timeout-p &optional baseline)
  "Build one diagnostics section plist for PATH, TEXT, TIMEOUT-P and BASELINE."
  (let* ((errors (kargu--loop-count-errors path text))
         (delta (kargu--loop-compare-diagnostics baseline path errors timeout-p text)))
    (list :path path
          :text (if timeout-p
                    (concat (or text "")
                            "\n(diagnostics did not settle before the timeout)")
                  (or text "(diagnostics unavailable)"))
          :unavailable (null text)
          :errors errors
          :baseline-available (plist-get delta :baseline-available)
          :new-errors (plist-get delta :new-errors)
          :pre-existing-errors (plist-get delta :pre-existing-errors)
          :resolved-errors (plist-get delta :resolved-errors)
          :unclassified-errors (plist-get delta :unclassified-errors)
          :timeout (and timeout-p t))))

(defun kargu--loop-sections-timed-out-p (sections)
  "Non-nil when any section in SECTIONS timed out."
  (cl-some (lambda (section) (plist-get section :timeout)) sections))

(defun kargu--loop-count-errors (path text)
  "Count error-severity diagnostics for PATH using structured data or TEXT."
  (let ((count 0) (text (or text "")))
    (dolist (diag (and (fboundp 'kargu-lsp-diagnostics-snapshot)
                      (kargu-lsp-diagnostics-snapshot path)))
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

(defun kargu--loop-count-section-new-errors (sections)
  "Sum the :new-errors counts of SECTIONS (falling back to :errors)."
  (let ((total 0))
    (dolist (section sections)
      (setq total (+ total (or (plist-get section :new-errors)
                               (plist-get section :errors)
                               0))))
    total))

(defun kargu--loop-count-section-field (sections key)
  "Sum integer KEY across SECTIONS."
  (let ((total 0))
    (dolist (section sections)
      (setq total (+ total (or (plist-get section key) 0))))
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
  (let ((has-baseline (seq-some (lambda (s) (plist-get s :baseline-available)) sections))
        (new-errors (kargu--loop-count-section-new-errors sections))
        (pre-existing (kargu--loop-count-section-field sections :pre-existing-errors))
        (resolved (kargu--loop-count-section-field sections :resolved-errors)))
    (cond
     ((seq-some (lambda (section) (plist-get section :unavailable)) sections)
      "\n\nVerification incomplete: diagnostics are unavailable. Do not treat this edit as clean.")
     ((kargu--loop-sections-timed-out-p sections)
      "\n\nVerification incomplete: diagnostics timed out before a settled snapshot. Do not treat this edit as clean.")
     ((and (> errors 0) has-baseline (= new-errors 0)
           (seq-every-p (lambda (s) (plist-get s :baseline-available)) sections))
      (format "\n\nBaseline comparison: 0 new error(s), %d pre-existing error(s), %d resolved error(s). No new regressions observed in the edited file diagnostics; project-wide effects are unverified."
              pre-existing resolved))
     ((> new-errors 0)
      (concat
       (format "\n\nSELF-HEALING (round %d of %d): the edited file reports %d error(s) above (Flymake / LSP).  Fix them now with a corrected edit_file (unique old_string / new_string), or explain why they are pre-existing."
               (1+ healing) kargu-max-healing-steps errors)
       (if has-baseline
           (format " [Baseline delta: %d new, %d pre-existing, %d resolved error(s)]"
                   new-errors pre-existing resolved)
         "")))
     ((> errors 0)
      "\n\nBaseline comparison unavailable: observed errors cannot be classified as new or pre-existing. Do not claim a regression-free edit.")
     (t
      (concat
       "\n\nVerification passed: the edited file reports no errors (Flymake & LSP clean)."
       (if (and has-baseline (> resolved 0))
           (format " [Resolved %d pre-existing error(s)]" resolved)
         ""))))))

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
