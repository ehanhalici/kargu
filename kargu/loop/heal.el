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
(declare-function kargu-lsp-current-diagnostics-p "kargu/tools/lsp/freshness" (buffer))
(declare-function kargu-lsp--diagnostic-backends "kargu/tools/lsp/freshness" ())
(declare-function eglot-current-server "eglot" ())
(declare-function jsonrpc--process "jsonrpc" (connection))
(defvar eglot--managed-mode)
(defvar eglot--versioned-identifier)
(defvar flymake-mode)
(defvar kargu-bridge-edit-document--id)

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
(declare-function kargu-diff-change-p "kargu/tools/diff/track" (object))
(declare-function kargu-diff-change-identity "kargu/tools/diff/track" (change))

(cl-defstruct (kargu--verification (:constructor kargu--make-verification))
  "One verification batch with a task owning its pending edit records."
  run id name result queue pending changes baselines done completed task)

(defun kargu--loop-native-change-p (change)
  "Return non-nil when CHANGE carries a native publication identity."
  (let ((id (and (kargu-diff-change-p change)
                 (kargu-diff-change-identity change))))
    (and (listp id) (plist-get id :native))))

(defun kargu--loop-native-target-valid-p (change path)
  "Whether CHANGE still points to an open live document matching PATH."
  (if (not (kargu--loop-native-change-p change))
      t
    (let ((id (kargu-diff-change-identity change)))
      (and (not (plist-get id :deleted))
           (not (plist-get id :closed))
           (or (and (null (plist-get id :document-id))
                    (null (plist-get id :document-tick)))
               (let ((buf (find-buffer-visiting path)))
                 (and (buffer-live-p buf)
                      (with-current-buffer buf
                        (let ((doc-id (and (boundp 'kargu-bridge-edit-document--id)
                                           (eq (car-safe kargu-bridge-edit-document--id) buf)
                                           (cdr kargu-bridge-edit-document--id))))
                          (and (or (null (plist-get id :document-id))
                                   (equal doc-id (plist-get id :document-id)))
                               (or (not (integerp (plist-get id :document-tick)))
                                   (= (buffer-chars-modified-tick)
                                      (plist-get id :document-tick)))))))))))))

(defun kargu--loop-section-settled-p (section)
  "Whether SECTION represents a clean or regression-free terminal check."
  (and section
       (not (plist-get section :unavailable))
       (not (plist-get section :timeout))
       (let ((errors (or (plist-get section :errors) 0))
             (new-errors (or (plist-get section :new-errors) 0)))
         (or (= errors 0)
             (and (plist-get section :baseline-available)
                  (= new-errors 0))))))

(defun kargu--loop-verify-files (run id name result queue files)
  "Collect FILES diagnostics for ID and NAME on RUN after RESULT, then QUEUE.
This entry point retains the after-tool dispatcher's positional signature."
  (when (kargu-loop--live-p run)
    (let* ((changes nil)
           (baselines nil)
           (_ (dolist (file files)
                (when-let* ((ch (kargu-edit-changes :capture file)))
                  (push (cons file ch) changes)
                  (push (cons file (kargu-edit-changes :baseline ch)) baselines))))
           (changes (nreverse changes))
           (verification (kargu--make-verification
                          :run run :id id :name name :result result :queue queue
                          :pending files :changes changes :baselines baselines))
           (task (kargu-async-start
                  (lambda (sections error)
                    (kargu--loop-publish-verification verification sections error))
                  :cancel (lambda ()
                            (dolist (entry (kargu--verification-changes verification))
                              (let* ((file (car entry))
                                     (change (cdr entry)))
                                (if (not (kargu--loop-native-change-p change))
                                    (kargu-edit-changes :consume change)
                                  (let ((section (cl-find file (kargu--verification-done verification)
                                                          :key (lambda (s) (plist-get s :path))
                                                          :test #'equal))
                                        (vtask (kargu--verification-task verification)))
                                    (when (and (kargu--verification-completed verification)
                                               vtask
                                               (eq (kargu-async-task-state vtask) :done)
                                               (buffer-live-p (kargu-async-task-buffer vtask))
                                               (kargu--loop-native-target-valid-p change file)
                                               (kargu--loop-section-settled-p section))
                                      (kargu-edit-changes :consume change))))))))))
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
      (let* ((errors (kargu--loop-count-section-errors sections))
             (new-errors (kargu--loop-count-section-new-errors sections))
             (sig (kargu--loop-sections-healing-sig sections))
             (prev-sig (plist-get run :healing-sig))
             (repeated (and (> new-errors 0) sig prev-sig (equal sig prev-sig)))
             (healing (or (plist-get run :healing) 0)))
        (cond
         (repeated
          (plist-put run :healing kargu-max-healing-steps))
         ((> new-errors 0)
          (plist-put run :healing-sig sig)
          (plist-put run :healing (1+ healing)))
         ((cl-every #'kargu--loop-section-settled-p sections)
          (plist-put run :healing-sig nil)))
        (kargu-log 'info "loop: verification done, %d error(s) (%d new)" errors new-errors)
        (kargu--loop-add-result-and-continue
         run (kargu--verification-id verification) (kargu--verification-name verification)
         (kargu--loop-compose-verified
          (kargu--verification-result verification) sections errors
          (if repeated :repeated healing))
         (kargu--verification-queue verification))))))

(defun kargu--loop-verify-next (verification)
  "Collect the next file for VERIFICATION without consuming a newer edit."
  (let ((run (kargu--verification-run verification))
        (task (kargu--verification-task verification))
        (pending (kargu--verification-pending verification)))
    (cond
     ((not (kargu-loop--live-p run)) nil)
     ((null pending)
      (setf (kargu--verification-completed verification) t)
      (kargu-async-finish task (reverse (kargu--verification-done verification))))
     (t
      (let* ((target (car pending))
             (change (cdr (assoc target (kargu--verification-changes verification))))
             (baseline (cdr (assoc target (kargu--verification-baselines verification)))))
        (kargu-loop--wait-diagnostics
         target
         (kargu-async-wrap
          task (lambda (path text timeout-p)
                 (when (and (kargu-loop--live-p run)
                            (eq pending (kargu--verification-pending verification)))
                   (let ((valid (kargu--loop-native-target-valid-p change target)))
                     (kargu-log 'info "loop: diagnostics %s for %s"
                                (cond ((not valid) "invalidated")
                                      (timeout-p "timed out")
                                      (t "settled"))
                                path)
                     (push (kargu--loop-diag-section
                            target (and valid text) (and valid timeout-p) baseline)
                           (kargu--verification-done verification))
                     (setf (kargu--verification-pending verification) (cdr pending))
                     (kargu--loop-verify-next verification)))))))))))

(defun kargu--loop-diag-key (diag)
  "Return position-independent semantic key for diagnostic plist DIAG."
  (list (plist-get diag :severity)
        (plist-get diag :source)
        (plist-get diag :code)
        (plist-get diag :message)))

(defun kargu--loop-baseline-compatible-p (baseline path)
  "Whether BASELINE's captured document and producer identity still match PATH."
  (let ((has-meta (or (plist-member baseline :buffer)
                      (plist-member baseline :document-id)
                      (plist-member baseline :tick)
                      (plist-member baseline :server)
                      (plist-member baseline :server-process)
                      (plist-member baseline :backends))))
    (if (not has-meta)
        t
      (let ((buf (find-buffer-visiting path)))
        (and (buffer-live-p buf)
             (or (not (plist-member baseline :buffer))
                 (eq buf (plist-get baseline :buffer)))
             (or (not (fboundp 'kargu-lsp-current-diagnostics-p))
                 (kargu-lsp-current-diagnostics-p buf))
             (with-current-buffer buf
               (let* ((doc-id (and (boundp 'kargu-bridge-edit-document--id)
                                   (eq (car-safe kargu-bridge-edit-document--id) buf)
                                   (cdr kargu-bridge-edit-document--id)))
                      (server (and (bound-and-true-p eglot--managed-mode)
                                   (fboundp 'eglot-current-server)
                                   (eglot-current-server)))
                      (proc (and server (fboundp 'jsonrpc--process)
                                 (ignore-errors (jsonrpc--process server))))
                      (ver (and (boundp 'eglot--versioned-identifier)
                                eglot--versioned-identifier))
                      (backends (and (bound-and-true-p flymake-mode)
                                     (fboundp 'kargu-lsp--diagnostic-backends)
                                     (kargu-lsp--diagnostic-backends))))
                 (and (or (not (plist-get baseline :document-id))
                          (equal doc-id (plist-get baseline :document-id)))
                      (or (not (integerp (plist-get baseline :tick)))
                          (> (buffer-chars-modified-tick) (plist-get baseline :tick)))
                      (or (not (plist-member baseline :server))
                          (and (eq server (plist-get baseline :server))
                               (or (null server)
                                   (and (processp proc) (process-live-p proc)
                                        (or (not (and (integerp (plist-get baseline :server-version))
                                                      (integerp ver)))
                                            (> ver (plist-get baseline :server-version)))))))
                      (or (not (plist-member baseline :server-process))
                          (eq proc (plist-get baseline :server-process)))
                      (or (not (plist-member baseline :backends))
                          (let ((base-backends (plist-get baseline :backends)))
                            (and (= (length base-backends) (length backends))
                                 (cl-every (lambda (b) (memq b backends)) base-backends)
                                 (cl-every (lambda (b) (memq b base-backends)) backends))))))))))))

(defun kargu--loop-compare-diagnostics (baseline path total-errors timeout-p text)
  "Compare BASELINE against settled diagnostics for PATH with TOTAL-ERRORS.
TIMEOUT-P or missing TEXT prevents a verified delta.
Return (:baseline-available BOOL :new-errors INT :pre-existing-errors INT
:resolved-errors INT)."
  (if (or timeout-p (null text) (null baseline)
          (not (plist-get baseline :available))
          (not (kargu--loop-baseline-compatible-p baseline path))
          (not (fboundp 'kargu-lsp-diagnostics-snapshot)))
      (list :baseline-available nil
            :new-errors 0 :unclassified-errors total-errors
            :pre-existing-errors 0
            :resolved-errors 0
            :new-error-keys nil)
    (let* ((base-errs (seq-filter (lambda (d) (eq (plist-get d :severity) 1))
                                  (plist-get baseline :diagnostics)))
           (post-errs (seq-filter (lambda (d) (eq (plist-get d :severity) 1))
                                  (kargu-lsp-diagnostics-snapshot path)))
           (pool (make-hash-table :test #'equal))
           (new-count 0)
           (new-keys nil)
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
            (setq new-count (1+ new-count))
            (push (cons path k) new-keys))))
      (maphash (lambda (_k rem) (setq resolved-count (+ resolved-count rem))) pool)
      (list :baseline-available t
            :new-errors new-count
            :pre-existing-errors pre-existing-count
            :resolved-errors resolved-count
            :new-error-keys (nreverse new-keys)))))

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
          :new-error-keys (plist-get delta :new-error-keys)
          :timeout (and timeout-p t))))

(defun kargu--loop-sections-healing-sig (sections)
  "Return canonical signature of new diagnostic errors across SECTIONS."
  (let ((keys nil))
    (dolist (section sections)
      (dolist (k (plist-get section :new-error-keys))
        (push k keys)))
    (and keys
         (sort keys (lambda (a b)
                      (string< (prin1-to-string a) (prin1-to-string b)))))))

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
     ((and (> new-errors 0) (eq healing :repeated))
      (concat
       (format "\n\nSELF-HEALING STOPPED: identical diagnostic error(s) repeated (%d error(s) above). Do not repeat the same fix; inspect the diagnostics or stop."
               errors)
       (if has-baseline
           (format " [Baseline delta: %d new, %d pre-existing, %d resolved error(s)]"
                   new-errors pre-existing resolved)
         "")))
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
