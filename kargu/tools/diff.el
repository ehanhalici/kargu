;;; diff.el --- Shadow buffers, ediff, rollback -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Shadow buffers, ediff review, rollback, and editing tools facade.
;; Requires: `kargu/core', `kargu/api', `kargu/tools/lsp'.
;;
;; Sub-modules:
;; - `kargu/tools/diff/track': rollback snapshots, run modified files, diff stats
;; - `kargu/tools/diff/stage': shadow buffer management and proposal staging
;; - `kargu/tools/diff/review': ediff interaction, session management, and finalization
;;
;; Public: `kargu-diff-apply-replace', `kargu-diff-apply-proposal',
;; `kargu-diff-rollback', `kargu-diff-changed-files', `kargu-diff-read-file',
;; `kargu-diff-apply-patch', `kargu-diff-review'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'rx)
(require 'kargu/application/execution)
(require 'ediff)

(require 'kargu/core)
(require 'kargu/contract)
(require 'kargu/async)
(require 'kargu/state/selectors)
(require 'kargu/api/tools)
(require 'kargu/permission)
(require 'kargu/files)
(require 'kargu/edit)
(require 'kargu/tools/process)

;;;; Customization --------------------------------------------------------

(defgroup kargu-diff nil
  "Shadow-buffer editing, ediff approval and rollback."
  :group 'kargu
  :prefix "kargu-diff-")

(defcustom kargu-diff-review-mode 'auto
  "How proposed file modifications are applied during agent runs.
`auto'      apply and save proposed edits immediately during the
            agent run without interactive ediff interruptions.
            Rollback snapshots are kept so the user can review
            changes via `kargu-diff-review' or roll back via
            `kargu-diff-rollback' after the run finishes.
`blocking'  an ediff session pops up for human hunk-by-hunk approval
            before anything is saved to disk; the tool result is
            delivered when the human quits ediff (Emacs never waits).
`async'     the tool returns immediately with a STAGED result;
            the final outcome is delivered when ediff is quitted."
  :type '(choice (const :tag "Auto-apply and save (review afterwards)" auto)
                 (const :tag "Block on ediff review before each edit" blocking)
                 (const :tag "Return immediately, notify later" async))
  :group 'kargu-diff)

(defcustom kargu-diff-auto-save t
  "Save the file buffer automatically after an approved review.
The human just approved each hunk explicitly, so saving is the
expected outcome.  When nil the buffer stays modified and the
user saves (or reverts) it manually."
  :type 'boolean
  :group 'kargu-diff)

(defcustom kargu-diff-keep-shadow nil
  "Keep shadow buffers (*kargu-shadow:...*) after review.
Useful to inspect exactly what was proposed; shadows are
otherwise killed shortly after the review finishes."
  :type 'boolean
  :group 'kargu-diff)

(defcustom kargu-diff-max-patch-bytes (* 4 1024 1024)
  "Maximum Unified Diff input size in bytes before parsing or staging."
  :type 'natnum
  :group 'kargu-diff)


(defcustom kargu-diff-ediff-window-setup-function #'ediff-setup-windows-plain
  "Function called by ediff to set up windows during kargu reviews.
Defaults to `ediff-setup-windows-plain' so that ediff runs within the
current Emacs frame instead of spawning external OS frames (especially
important in tiling window managers like i3wm)."
  :type 'function
  :group 'kargu-diff)

(defcustom kargu-diff-ediff-split-window-function #'split-window-horizontally
  "Function used by ediff to split the window between Buffer A and Buffer B.
Defaults to `split-window-horizontally' so that Buffer A (old code) is on
the left and Buffer B (new code) is on the right."
  :type 'function
  :group 'kargu-diff)

(defcustom kargu-diff-after-apply-hook nil
  "Hook run after an approved proposal is saved to its file.
Runs with the file's buffer current;
`kargu-diff--current-file' holds the absolute path.  The
agent loop uses this (or the changed-file set) to trigger
diagnostics verification."
  :type 'hook
  :group 'kargu-diff)

(require 'kargu/tools/diff/context)
(require 'kargu/tools/diff/track)
(require 'kargu/tools/diff/stage)
(require 'kargu/tools/diff/review)

(defalias 'kargu-diff-read-file #'kargu-file-read)

;;;; Tool registration -----------------------------------------------------

(defun kargu-diff--mutating-disabled (name)
  "Return an error string when mutating tool NAME is blocked."
  (let ((mode (kargu-state-mode)))
    (unless (eq mode 'agent)
      (format
       "ERROR: %s is disabled in %s mode; switch to agent mode (M-x kargu-set-mode) before modifying files"
       name mode))))

(defun kargu-diff--with-review-callback (callback run)
  "Run RUN for an editing tool and deliver its result.
RUN takes the outcome callback DONE, which is non-nil only when the tool
was called asynchronously in `blocking' review mode: the result then
arrives once the human finishes the ediff review, without ever waiting for
it.  RUN returns the result string, or `deferred' when DONE will deliver it.
Without CALLBACK the string is returned; with CALLBACK it is passed there."
  (let* ((done (and callback
                    (eq kargu-diff-review-mode 'blocking)
                    (lambda (outcome)
                      (funcall callback (kargu-diff--describe outcome)))))
         (result (condition-case-unless-debug err
                     (funcall run done)
                   (error (format "ERROR: %s" (error-message-string err))))))
    (cond
     ((eq result 'deferred) nil)
     (callback (funcall callback result) nil)
     (t result))))

(defun kargu-diff--edit-file-tool (args &optional callback)
  "Edit the unique text from ARGS, reporting the result to CALLBACK."
  (kargu-diff--with-review-callback
   callback (lambda (done) (kargu-diff--edit-file-result args done))))

(defun kargu-diff--edit-file-result (args done)
  "Result of an `edit_file' call with ARGS; DONE is the outcome callback."
  (or (kargu-diff--mutating-disabled "edit_file")
      (let ((path (kargu--tool-file-path args))
            (old (kargu--tool-arg-string args "old_string" "oldString" "old_text"))
            (new (kargu--tool-arg-string args "new_string" "newString" "new_text"))
            (reason (kargu--tool-arg args "reason")))
        (cond
         ((not (kargu-nonempty path))
          (kargu--tool-missing-file-path args))
         ((or (null old) (not (stringp old)) (string-empty-p old))
          "ERROR: old_string is required and must be a unique exact block from the file")
         ((null new)
          "ERROR: new_string is required (use an empty string to delete the block)")
         ((not (stringp new))
          "ERROR: new_string must be a string")
         (t
          (when (and (stringp reason) (not (string-empty-p reason)))
            (message "kargu edit proposal for %s: %s" path reason)
            (kargu-log 'info "diff: edit reason: %s" reason))
          (let ((outcome (kargu-diff-apply-replace path old new done)))
            (if done 'deferred (kargu-diff--describe outcome))))))))

(defun kargu-diff--write-file-tool (args &optional callback)
  "Write the file described by ARGS, reporting the result to CALLBACK."
  (kargu-diff--with-review-callback
   callback (lambda (done) (kargu-diff--write-file-result args done))))

(defun kargu-diff--write-file-result (args done)
  "Result of a `write_file' call with ARGS; DONE is the outcome callback."
  (or (kargu-diff--mutating-disabled "write_file")
      (let ((path (kargu--tool-file-path args))
            (contents (kargu--tool-arg-string args "contents" "content"))
            (reason (kargu--tool-arg args "reason")))
        (cond
         ((not (kargu-nonempty path))
          (kargu--tool-missing-file-path args))
         ((null contents)
          "ERROR: contents is required")
         ((not (stringp contents))
          "ERROR: contents must be a string")
         (t
          (let ((abs (ignore-errors (kargu-permission-resolve path "file"))))
            (cond
             ((and abs (file-directory-p abs))
              (format "ERROR: %s is a directory" abs))
             (t
              (when (and (stringp reason) (not (string-empty-p reason)))
                (message "kargu write proposal for %s: %s" path reason)
                (kargu-log 'info "diff: write reason: %s" reason))
              (let ((outcome (kargu-diff-apply-proposal path contents done)))
                (if done 'deferred (kargu-diff--describe outcome)))))))))))

;;;; Unified Diff parsing and isolated git apply ----------------------------

(defun kargu-diff--validate-unified-line (line)
  "Reject unsupported or legacy directives in unified diff LINE."
  (cond
   ((string-prefix-p "*** " line)
    (error "Unsupported patch directive: %s; use standard Unified Diff (--- a/file, +++ b/file)"
           line))
   ((or (string-prefix-p "GIT binary patch" line)
        (and (string-prefix-p "Binary files " line)
             (string-suffix-p " differ" line)))
    (error "Unsupported binary patch directive: %s" line))
   ((or (string-match-p (rx string-start (or "rename" "copy") " " (or "from" "to") " ") line)
        (string-match-p (rx string-start (or "similarity" "dissimilarity") " index ") line))
    (error "Unsupported rename or copy directive in patch: %s" line))
   ((string-match-p (rx string-start (or "old" "new") " mode ") line)
    (error "Unsupported file mode change in patch: %s" line))
   ((and (string-match (rx string-start (or "new" "deleted") " file mode "
                            (group (* nonl)) string-end) line)
         (not (equal (string-trim (match-string 1 line)) "100644")))
    (error "Unsupported file mode in patch: %s" line))))

(defun kargu-diff--clean-header-path (raw prefix)
  "Extract relative path from unified diff header RAW, stripping PREFIX.
Return nil for `/dev/null'."
  (let* ((spec (string-trim (car (split-string raw "\t"))))
         (unquoted (if (and (>= (length spec) 2)
                            (string-prefix-p "\"" spec)
                            (string-suffix-p "\"" spec))
                       (substring spec 1 -1)
                     spec)))
    (cond
     ((equal unquoted "/dev/null") nil)
     ((string-empty-p unquoted)
      (error "Empty file path in unified diff header"))
     ((string-prefix-p prefix unquoted)
      (substring unquoted (length prefix)))
     (t unquoted))))

(defun kargu-diff--parse-header-pair (old-line new-line)
  "Parse `---' OLD-LINE and `+++' NEW-LINE into a file operation plist."
  (unless (and (stringp new-line) (string-prefix-p "+++ " new-line))
    (error "Expected '+++ ' header after '%s'" old-line))
  (let* ((old-rel (kargu-diff--clean-header-path (substring old-line 4) "a/"))
         (new-rel (kargu-diff--clean-header-path (substring new-line 4) "b/")))
    (when (and (null old-rel) (null new-rel))
      (error "Invalid unified diff header: both old and new paths are /dev/null"))
    (when (and old-rel new-rel (not (equal old-rel new-rel)))
      (error "Unsupported rename in unified diff: %s -> %s" old-rel new-rel))
    (let* ((rel (or new-rel old-rel))
           (abs (file-truename (kargu-permission-resolve rel "file")))
           (canon-rel (file-relative-name abs (kargu-permission-project-root)))
           (type (cond ((null old-rel) 'add)
                       ((null new-rel) 'delete)
                       (t 'update))))
      (unless (and (kargu-permission-within-project-p abs)
                   (not (file-name-absolute-p canon-rel))
                   (not (member ".." (split-string canon-rel "/")))
                   (not (member (car (split-string canon-rel "/"))
                                '(".git" ".kargu.patch"))))
        (error "Patch target must remain inside the isolated workspace: %s" rel))
      (list :type type :rel rel :abs abs :canon-rel canon-rel :hunks nil))))

(defun kargu-diff--parse-hunk-counts (header)
  "Parse `@@ -O,C +N,C @@' HEADER and return (OLD-COUNT . NEW-COUNT)."
  (unless (string-match
           (rx string-start "@@ -" (group (+ digit)) (optional "," (group (+ digit)))
               " +" (group (+ digit)) (optional "," (group (+ digit))) " @@")
           header)
    (error "Malformed unified diff hunk header: %s" header))
  (let ((old-count (if (match-string 2 header)
                       (string-to-number (match-string 2 header))
                     1))
        (new-count (if (match-string 4 header)
                       (string-to-number (match-string 4 header))
                     1)))
    (cons old-count new-count)))

(defun kargu-diff--emit-normalized-header (op)
  "Return normalized `git apply -p1' header lines for OP."
  (let ((type (plist-get op :type))
        (canon (plist-get op :canon-rel)))
    (delq nil
          (list (format "diff --git a/%s b/%s" canon canon)
                (cond ((eq type 'add) "new file mode 100644")
                      ((eq type 'delete) "deleted file mode 100644"))
                (if (eq type 'add) "--- /dev/null" (format "--- a/%s" canon))
                (if (eq type 'delete) "+++ /dev/null" (format "+++ b/%s" canon))))))

(defun kargu-diff--step-hunk-line (line old-rem new-rem)
  "Advance (OLD-REM . NEW-REM) for hunk body LINE, or signal on malformed input."
  (cond
   ((string-prefix-p " " line)
    (when (or (<= old-rem 0) (<= new-rem 0))
      (error "Unexpected context line past hunk end: %s" line))
    (cons (1- old-rem) (1- new-rem)))
   ((string-prefix-p "-" line)
    (when (<= old-rem 0)
      (error "Unexpected deletion line past hunk end: %s" line))
    (cons (1- old-rem) new-rem))
   ((string-prefix-p "+" line)
    (when (<= new-rem 0)
      (error "Unexpected addition line past hunk end: %s" line))
    (cons old-rem (1- new-rem)))
   ((string-prefix-p "\\ No newline at end of file" line)
    (cons old-rem new-rem))
   (t
    (error "Malformed unified diff hunk line: %s" line))))

(cl-defstruct (kargu-diff--patch-reader (:constructor kargu-diff--make-patch-reader))
  "Unified Diff framing state; Git alone matches and applies the hunks."
  (phase :header) lines operations current hunk output (old-left 0) (new-left 0))

(defun kargu-diff--flush-reader-hunk (reader)
  "Attach READER's completed hunk to its current operation."
  (when-let* ((hunk (kargu-diff--patch-reader-hunk reader)))
    (let ((operation (kargu-diff--patch-reader-current reader)))
      (plist-put operation :hunks (cons (nreverse hunk) (plist-get operation :hunks))))
    (setf (kargu-diff--patch-reader-hunk reader) nil)))

(defun kargu-diff--flush-reader-file (reader)
  "Attach READER's completed operation to the validated target list."
  (kargu-diff--flush-reader-hunk reader)
  (when-let* ((operation (kargu-diff--patch-reader-current reader)))
    (plist-put operation :hunks (nreverse (plist-get operation :hunks)))
    (push operation (kargu-diff--patch-reader-operations reader))
    (setf (kargu-diff--patch-reader-current reader) nil)))

(defun kargu-diff--read-patch-header (reader line)
  "Consume one framing LINE in READER without interpreting hunk matching."
  (kargu-diff--validate-unified-line line)
  (cond
   ((or (string-empty-p (string-trim line))
        (string-prefix-p "diff --git " line) (string-prefix-p "index " line)
        (member line '("new file mode 100644" "deleted file mode 100644"))) nil)
   ((string-prefix-p "\\ No newline at end of file" line)
    (push line (kargu-diff--patch-reader-output reader)))
   ((string-prefix-p "--- " line)
    (kargu-diff--flush-reader-file reader)
    (let ((operation (kargu-diff--parse-header-pair
                      line (pop (kargu-diff--patch-reader-lines reader)))))
      (setf (kargu-diff--patch-reader-current reader) operation)
      (dolist (header (kargu-diff--emit-normalized-header operation))
        (push header (kargu-diff--patch-reader-output reader)))))
   ((string-prefix-p "@@" line)
    (unless (kargu-diff--patch-reader-current reader)
      (error "Hunk header without file header: %s" line))
    (kargu-diff--flush-reader-hunk reader)
    (let ((counts (kargu-diff--parse-hunk-counts line)))
      (setf (kargu-diff--patch-reader-old-left reader) (car counts)
            (kargu-diff--patch-reader-new-left reader) (cdr counts)
            (kargu-diff--patch-reader-phase reader)
            (if (or (> (car counts) 0) (> (cdr counts) 0)) :hunk :header)))
    (push line (kargu-diff--patch-reader-output reader)))
   (t (error "Unexpected line in unified diff: %s" line))))

(defun kargu-diff--read-patch-body (reader line)
  "Consume one hunk body LINE in READER, retaining header-like source text."
  (let ((remaining (kargu-diff--step-hunk-line
                    line (kargu-diff--patch-reader-old-left reader)
                    (kargu-diff--patch-reader-new-left reader))))
    (setf (kargu-diff--patch-reader-old-left reader) (car remaining)
          (kargu-diff--patch-reader-new-left reader) (cdr remaining)
          (kargu-diff--patch-reader-phase reader)
          (if (and (zerop (car remaining)) (zerop (cdr remaining))) :header :hunk))
    (push line (kargu-diff--patch-reader-hunk reader))
    (push line (kargu-diff--patch-reader-output reader))))

(defun kargu-diff--parse-unified-patch (patch-text)
  "Validate Unified Diff PATCH-TEXT framing and return isolated backend input."
  (let* ((normalized (replace-regexp-in-string "\r\n" "\n" patch-text t t))
         (lines (split-string normalized "\n"))
         (reader (kargu-diff--make-patch-reader
                  :lines (if (equal (car (last lines)) "") (butlast lines) lines))))
    (while (kargu-diff--patch-reader-lines reader)
      (let ((line (pop (kargu-diff--patch-reader-lines reader))))
        (pcase (kargu-diff--patch-reader-phase reader)
          (:header (kargu-diff--read-patch-header reader line))
          (:hunk (kargu-diff--read-patch-body reader line)))))
    (when (eq (kargu-diff--patch-reader-phase reader) :hunk)
      (error "Incomplete unified diff hunk at end of patch"))
    (kargu-diff--flush-reader-file reader)
    (unless (kargu-diff--patch-reader-operations reader)
      (error "No valid unified diff operations found (expected '--- a/file' and '+++ b/file')"))
    (list :ops (nreverse (kargu-diff--patch-reader-operations reader))
          :patch (concat (string-join (nreverse (kargu-diff--patch-reader-output reader)) "\n")
                         "\n"))))

(defun kargu-diff--check-zero-context-hunks (orig rel hunks)
  "Verify zero-context HUNKS in REL match uniquely in ORIG."
  (dolist (hunk hunks)
    (let ((has-context (seq-some (lambda (l) (string-prefix-p " " l)) hunk))
          (removed (delq nil (mapcar (lambda (l)
                                       (and (string-prefix-p "-" l) (substring l 1)))
                                     hunk))))
      (when (and (not has-context) removed)
        (let* ((old-block (string-join removed "\n"))
               (matches (kargu-diff--count-literal orig old-block)))
          (cond
           ((= matches 0)
            (error "Hunk failed to match in %s: %s"
                   rel (truncate-string-to-width old-block 60)))
           ((> matches 1)
            (error "Hunk matched %d times in %s; include context lines to disambiguate"
                   matches rel))))))))

(defun kargu-diff--prepare-patch-targets (ops)
  "Capture pre-states and validate existence rules across OPS.
Return an ordered list of target plists."
  (let ((pre-states (make-hash-table :test #'equal))
        (sim-text (make-hash-table :test #'equal))
        (targets nil))
    (dolist (op ops)
      (let* ((abs (plist-get op :abs))
             (rel (plist-get op :rel))
             (canon-rel (plist-get op :canon-rel))
             (type (plist-get op :type))
             (hunks (plist-get op :hunks))
             (pre-state (or (gethash abs pre-states)
                            (let ((s (kargu-diff--capture-pre-state abs)))
                              (puthash abs s pre-states)
                              (when (plist-get s :exists)
                                (puthash abs (or (plist-get s :original) "") sim-text))
                              s)))
             (current (gethash abs sim-text)))
        (pcase type
          ('add
           (when current
             (error "Cannot add %s: it already exists; use an update diff" rel))
           (puthash abs "" sim-text))
          ('update
           (unless current
             (error "Cannot update %s: no such file" rel))
           (kargu-diff--check-zero-context-hunks current rel hunks))
          ('delete
           (unless current
             (error "Cannot delete %s: no such file" rel))
           (unless (eq kargu-diff-review-mode 'auto)
             (error "Deleting %s through a patch is only supported in `auto' review mode; delete it with the bash tool, which asks for approval"
                    rel))
           (remhash abs sim-text)))
        (let ((existing (cl-find abs targets :key (lambda (it) (plist-get it :abs)) :test #'equal)))
          (if existing
              (plist-put existing :final-type type)
            (push (list :abs abs :rel rel :canon-rel canon-rel
                        :final-type type :pre-state pre-state)
                  targets)))))
    (nreverse targets)))

(defun kargu-diff--setup-isolated-patch-workspace (targets patch-string)
  "Create isolated temp directory with TARGETS snapshots and PATCH-STRING."
  (let ((tmp-dir (make-temp-file "kargu-patch-" t))
        (service (kargu-diff--current-service)))
    (condition-case err
        (let ((git-dir (expand-file-name ".git" tmp-dir))
              (coding-system-for-write 'utf-8-unix))
          (kargu-edit-service-register-temp-dir service tmp-dir)
          (make-directory (expand-file-name "objects" git-dir) t)
          (make-directory (expand-file-name "refs" git-dir) t)
          (write-region "ref: refs/heads/main\n" nil (expand-file-name "HEAD" git-dir) nil 'silent)
          (dolist (target targets)
            (let* ((pre-state (plist-get target :pre-state))
                   (canon-rel (plist-get target :canon-rel))
                   (dest (expand-file-name canon-rel tmp-dir)))
              (when (plist-get pre-state :exists)
                (make-directory (file-name-directory dest) t)
                (write-region (or (plist-get pre-state :original) "") nil dest nil 'silent))))
          (write-region patch-string nil (expand-file-name ".kargu.patch" tmp-dir) nil 'silent)
          tmp-dir)
      (error
       (kargu-edit-service-unregister-temp-dir service tmp-dir)
       (ignore-errors (delete-directory tmp-dir t))
       (signal (car err) (cdr err))))))

(defun kargu-diff--collect-isolated-patch-plan (tmp-dir targets)
  "Read resulting files from TMP-DIR for TARGETS into an ordered plan alist."
  (let ((coding-system-for-read 'utf-8-unix)
        (plan nil))
    (dolist (target targets)
      (let* ((abs (plist-get target :abs))
             (canon-rel (plist-get target :canon-rel))
             (final-type (plist-get target :final-type))
             (pre-state (plist-get target :pre-state))
             (dest (expand-file-name canon-rel tmp-dir)))
        (if (or (eq final-type 'delete) (not (file-exists-p dest)))
            (push (cons abs (list :deleted (plist-get pre-state :original)
                                  :pre-state pre-state))
                  plan)
          (let ((new-text (with-temp-buffer
                            (insert-file-contents dest)
                            (buffer-string))))
            (push (cons abs (list :text new-text :pre-state pre-state)) plan)))))
    (nreverse plan)))

(defun kargu-diff--git-apply-args (tmp-dir)
  "Return `git' CLI arguments to apply `.kargu.patch' inside isolated TMP-DIR."
  (list (concat "--git-dir=" (expand-file-name ".git" tmp-dir))
        (concat "--work-tree=" tmp-dir)
        "-c" "apply.whitespace=nowarn" "-c" "core.autocrlf=false"
        "apply" "--unidiff-zero" "-p1" "--" ".kargu.patch"))

(defun kargu-diff--run-git-apply-sync (tmp-dir targets)
  "Run `git apply' synchronously in TMP-DIR and return planned TARGETS."
  (let ((exe (executable-find "git")))
    (unless exe
      (error "Git executable is required for apply_patch"))
    (with-temp-buffer
      (let* ((default-directory (file-name-as-directory tmp-dir))
             (code (apply #'call-process exe nil t nil (kargu-diff--git-apply-args tmp-dir))))
        (unless (zerop code)
          (error "Git apply failed (exit %s): %s" code (string-trim (buffer-string))))
        (kargu-diff--collect-isolated-patch-plan tmp-dir targets)))))

;;;; Patch transaction and batch rollback ----------------------------------

(defun kargu-diff--delete-file (file original &optional pre-state)
  "Delete FILE, keeping ORIGINAL and PRE-STATE as its rollback snapshot."
  (when pre-state
    (kargu-diff--validate-pre-state pre-state))
  (let ((snap (list :content original
                    :created-new nil
                    :deleted t
                    :at (current-time)
                    :coding (and pre-state (plist-get pre-state :coding))
                    :disk-revision (or (and pre-state (plist-get pre-state :disk-revision))
                                       (kargu-diff--disk-revision file))
                    :post-content nil
                    :post-tick nil
                    :post-disk-revision nil
                    :baseline-available (and pre-state (plist-get pre-state :baseline-available))
                    :baseline-diagnostics (and pre-state (plist-get pre-state :baseline-diagnostics)))))
    (when-let* ((buf (find-buffer-visiting file)))
      (unless (kill-buffer buf)
        (error "Deletion cancelled: buffer for %s could not be closed" file)))
    (when pre-state (kargu-diff--validate-pre-state pre-state))
    (delete-file file)
    (puthash file (cons snap (gethash file kargu-diff--snapshots))
             kargu-diff--snapshots)
    (puthash file (list :status :applied-full :saved t
                        :at (format-time-string "%H:%M:%S")
                        :baseline-available (plist-get snap :baseline-available)
                        :baseline-diagnostics (plist-get snap :baseline-diagnostics))
             kargu-diff--changed)
    (when (boundp 'kargu-diff--run-modified-files)
      (cl-pushnew file kargu-diff--run-modified-files :test #'equal))
    snap))

(cl-defstruct (kargu-diff--patch-batch (:constructor kargu-diff--make-patch-batch))
  "One patch's review outcomes, transaction state and single completion delivery."
  (state :launching) pending outcomes order committed callback owner)

(defun kargu-diff--patch-ordered-outcomes (batch)
  "Return outcomes of BATCH in target order."
  (let ((table (kargu-diff--patch-batch-outcomes batch))
        (order (kargu-diff--patch-batch-order batch)))
    (if order
        (delq nil (mapcar (lambda (file) (gethash file table)) order))
      (hash-table-values table))))

(defun kargu-diff--patch-summary (batch)
  "Describe BATCH without treating pending or rolled-back edits as applied."
  (if (> (kargu-diff--patch-batch-pending batch) 0)
      (format "STAGED: %d patch proposal(s) await human review; do not treat them as applied."
              (kargu-diff--patch-batch-pending batch))
    (let* ((outcomes (kargu-diff--patch-ordered-outcomes batch))
           (complete (and outcomes
                          (seq-every-p
                           (lambda (outcome)
                             (memq (plist-get outcome :status) '(:applied-full :unchanged)))
                           outcomes))))
      (format "%s to %d file(s):\n  • %s"
              (if complete "Patch successfully applied" "Patch NOT fully applied")
              (length outcomes)
              (mapconcat (lambda (outcome)
                           (or (plist-get outcome :message) (kargu-diff--describe outcome)))
                         outcomes "\n  • ")))))

(defun kargu-diff--rollback-batch-committed (batch)
  "Roll back files committed by BATCH that are still unmodified since commit."
  (let ((outcomes (kargu-diff--patch-batch-outcomes batch)))
    (dolist (pair (kargu-diff--patch-batch-committed batch))
      (let ((file (car pair))
            (snap (cdr pair)))
        (if (and snap (not (kargu-diff--snapshot-unmodified-since-commit-p file snap)))
            (puthash file
                     (list :status :conflict
                           :file file
                           :saved t
                           :message (format "CONFLICT: %s was modified after commit and kept to preserve user changes."
                                            file))
                     outcomes)
          (condition-case err
              (progn
                (when (gethash file (kargu-diff--service-snapshots))
                  (kargu-diff-rollback file t))
                (puthash file
                         (list :status :rolled-back
                               :file file
                               :saved nil
                               :message (format "ROLLED BACK: %s was restored to its pre-patch state after batch failure."
                                                file))
                         outcomes))
            (error
             (puthash file
                      (list :status :conflict
                            :file file
                            :saved t
                            :message (format "CONFLICT: could not roll back %s: %s"
                                             file (error-message-string err)))
                      outcomes))))))
    (setf (kargu-diff--patch-batch-committed batch) nil)))

(defun kargu-diff--cancel-deferred (batch deferred)
  "Cancel uncommitted DEFERRED decisions in BATCH without claiming application."
  (dolist (outcome deferred)
    (let* ((file (plist-get outcome :file))
           (current (gethash file (kargu-diff--patch-batch-outcomes batch))))
      (when (plist-get current :deferred)
        (puthash file
                 (list :status :interrupted :file file :saved nil
                       :message (format "CANCELLED: %s was not written after batch failure." file))
                 (kargu-diff--patch-batch-outcomes batch))))))

(defun kargu-diff--validate-deferred (batch deferred)
  "Validate all DEFERRED decisions in BATCH before any commit."
  (catch 'invalid
    (dolist (outcome deferred)
      (condition-case err
          (kargu-diff--validate-pre-state (plist-get outcome :pre-state))
        (error
         (puthash (plist-get outcome :file)
                  (list :status :conflict :file (plist-get outcome :file)
                        :saved nil :message (format "ERROR: %s" (error-message-string err)))
                  (kargu-diff--patch-batch-outcomes batch))
         (throw 'invalid nil))))
    t))

(defun kargu-diff--commit-deferred-file (batch outcome)
  "Commit one OUTCOME in BATCH, recording rollback identity before continuing."
  (let ((file (plist-get outcome :file)))
    (condition-case err
        (let ((committed (kargu-diff--commit-file-content
                          (plist-get outcome :pre-state)
                          (plist-get outcome :decided-content)
                          (plist-get outcome :status))))
          (when-let* ((snapshot (plist-get committed :snapshot)))
            (push (cons file snapshot) (kargu-diff--patch-batch-committed batch)))
          (puthash file committed (kargu-diff--patch-batch-outcomes batch))
          t)
      (error
       (puthash file (list :status :error :file file :saved nil
                          :message (format "ERROR: %s: %s" file (error-message-string err)))
                (kargu-diff--patch-batch-outcomes batch))
       nil))))

(defun kargu-diff--commit-deferred-batch (batch)
  "Validate and commit BATCH only after every review has settled."
  (let* ((ordered (kargu-diff--patch-ordered-outcomes batch))
         (deferred (seq-filter
                    (lambda (outcome)
                      (and (plist-get outcome :deferred)
                           (memq (plist-get outcome :status)
                                 '(:applied-full :applied-partial))))
                    ordered))
         (owner (kargu-diff--patch-batch-owner batch))
         (allowed (and (or (null owner) (eq owner kargu--loop-run))
                       (not (kargu-diff--batch-has-failure-p batch))
                       (kargu-diff--validate-deferred batch deferred))))
    (dolist (outcome deferred)
      (when allowed
        (setq allowed (kargu-diff--commit-deferred-file batch outcome))))
    (unless allowed (kargu-diff--cancel-deferred batch deferred))))

(defun kargu-diff--batch-has-failure-p (batch)
  "Return non-nil when any file in BATCH ended in error, conflict or interruption."
  (seq-some (lambda (outcome)
              (memq (plist-get outcome :status) '(:error :conflict :interrupted)))
            (kargu-diff--patch-ordered-outcomes batch)))

(defun kargu-diff--finish-patch (batch)
  "Deliver BATCH once after all proposals have reached a final outcome."
  (when (and (eq (kargu-diff--patch-batch-state batch) :waiting)
              (zerop (kargu-diff--patch-batch-pending batch)))
    (setf (kargu-diff--patch-batch-state batch) :done)
    (kargu-diff--commit-deferred-batch batch)
    (when (and (kargu-diff--batch-has-failure-p batch)
               (kargu-diff--patch-batch-committed batch))
      (kargu-diff--rollback-batch-committed batch))
    (when-let* ((callback (kargu-diff--patch-batch-callback batch)))
      (condition-case-unless-debug err
          (funcall callback (kargu-diff--patch-summary batch))
        (error (kargu-log 'error "Patch callback failed: %s" (error-message-string err)))))))

(defun kargu-diff--settle-patch-file (batch file outcome)
  "Record FILE's OUTCOME in BATCH, ignoring duplicate review delivery."
  (unless (gethash file (kargu-diff--patch-batch-outcomes batch))
    (when-let* ((snap (plist-get outcome :snapshot)))
      (push (cons file snap) (kargu-diff--patch-batch-committed batch)))
    (puthash file outcome (kargu-diff--patch-batch-outcomes batch))
    (cl-decf (kargu-diff--patch-batch-pending batch))
    (kargu-diff--finish-patch batch)))

(defun kargu-diff--stage-patch-file (batch file entry)
  "Stage FILE's planned ENTRY and collect its final outcome in BATCH."
  (let ((done (lambda (outcome) (kargu-diff--settle-patch-file batch file outcome)))
        (pre-state (plist-get (cddr entry) :pre-state)))
    (if (or (and (kargu-diff--patch-batch-owner batch)
                 (not (eq (kargu-diff--patch-batch-owner batch) kargu--loop-run)))
            (kargu-diff--batch-has-failure-p batch))
        (funcall done (list :status :interrupted :file file))
      (condition-case-unless-debug err
          (if (eq (car entry) :deleted)
              (let ((snap (kargu-diff--delete-file file (cadr entry) pre-state)))
                (funcall done (list :status :applied-full :file file :saved t :snapshot snap)))
            (let ((kargu-diff--active-pre-state pre-state)
                  (kargu-diff--batch-defer-commit
                   (not (and (boundp 'kargu-diff-review-mode)
                             (eq kargu-diff-review-mode 'auto)))))
              (kargu-diff-apply-proposal file (cadr entry) done)))
        (error (funcall done (list :status :error :file file
                                   :message (format "ERROR: %s: %s" file
                                                    (error-message-string err)))))))))

(defun kargu-diff--normalize-patch-entries (state)
  "Convert STATE (hash-table or alist) into an ordered alist of (FILE . ENTRY)."
  (if (hash-table-p state)
      (let (acc)
        (maphash (lambda (file entry) (push (cons file entry) acc)) state)
        (nreverse acc))
    state))

(defun kargu-diff--commit-patch (state callback)
  "Stage the proposals in STATE and report their final summary to CALLBACK."
  (let* ((entries (kargu-diff--normalize-patch-entries state))
         (batch (kargu-diff--make-patch-batch
                 :pending (length entries)
                 :outcomes (make-hash-table :test #'equal)
                 :order (mapcar #'car entries)
                 :callback callback
                 :owner kargu--loop-run)))
    (dolist (item entries)
      (kargu-diff--stage-patch-file batch (car item) (cdr item)))
    (setf (kargu-diff--patch-batch-state batch) :waiting)
    (kargu-diff--finish-patch batch)
    (kargu-diff--patch-summary batch)))

(defun kargu-diff--apply-patch-async (tmp-dir targets callback)
  "Run `git apply' asynchronously in TMP-DIR for TARGETS and call CALLBACK."
  (let* ((service (kargu-diff--current-service))
         (proc nil)
         (cleaned nil)
         (cleanup (lambda ()
                    (unless cleaned
                      (setq cleaned t)
                      (when (processp proc)
                        (kargu-edit-service-unregister-process service proc)
                        (kargu-process-cancel proc))
                      (kargu-edit-service-unregister-temp-dir service tmp-dir)
                      (ignore-errors (delete-directory tmp-dir t)))))
         (task (kargu-async-start
                (lambda (plan error)
                  (if error
                      (funcall callback (format "ERROR: %s" error))
                    (kargu-diff-with-service service
                      (kargu-diff--commit-patch plan callback))))
                :cancel cleanup)))
    (setq proc
          (kargu-process-run
           "git" (kargu-diff--git-apply-args tmp-dir)
           (lambda (res)
             (unwind-protect
                 (when (kargu-async-pending-p task)
                   (if (and (eql (plist-get res :code) 0)
                            (not (plist-get res :timed-out))
                            (not (plist-get res :truncated)))
                       (let ((plan (condition-case err
                                       (kargu-diff--collect-isolated-patch-plan tmp-dir targets)
                                     (error (cons :error (error-message-string err))))))
                         (if (eq (car-safe plan) :error)
                             (kargu-async-finish task nil (cdr plan))
                           (kargu-async-finish task plan nil)))
                     (kargu-async-finish task nil (kargu-process-failure "git apply" res))))
               (funcall cleanup)))
           :dir tmp-dir))
    (if proc
        (kargu-edit-service-register-process service proc)
      (funcall cleanup))
    nil))

(defun kargu-diff-apply-patch (patch-text &optional callback)
  "Validate and apply Unified Diff PATCH-TEXT in an isolated temporary workspace.
Check the entire patch before applying proposals through the review and
rollback pipeline.  Return a summary, or STAGED while review is pending.
When CALLBACK is non-nil, `git apply' runs asynchronously and CALLBACK
receives the final summary once all file reviews have finished."
  (kargu-contract-assert #'kargu-contract-non-empty-string-p patch-text
                         "PATCH-TEXT must be a non-empty string: %S" patch-text)
  (when (> (string-bytes patch-text) kargu-diff-max-patch-bytes)
    (error "Patch exceeds the %d-byte input limit" kargu-diff-max-patch-bytes))
  (let* ((parsed (kargu-diff--parse-unified-patch patch-text))
         (ops (plist-get parsed :ops))
         (norm-patch (plist-get parsed :patch))
         (targets (kargu-diff--prepare-patch-targets ops))
         (tmp-dir (kargu-diff--setup-isolated-patch-workspace targets norm-patch)))
    (if callback
        (kargu-diff--apply-patch-async tmp-dir targets callback)
      (let* ((service (kargu-diff--current-service))
             (plan (unwind-protect
                       (kargu-diff--run-git-apply-sync tmp-dir targets)
                     (kargu-edit-service-unregister-temp-dir service tmp-dir)
                     (ignore-errors (delete-directory tmp-dir t)))))
        (kargu-diff--commit-patch plan nil)))))

(defun kargu-diff--apply-patch-tool (args &optional callback)
  "Apply the patch in ARGS, reporting final review results to CALLBACK."
  (let ((delivered nil))
    (cl-labels ((deliver (text)
                  (unless delivered
                    (setq delivered t)
                    (if callback (funcall callback text) text))))
      (condition-case-unless-debug err
          (let* ((patch (kargu--tool-arg args "patch" "diff" "content"))
                 (failure (or (kargu-diff--mutating-disabled "apply_patch")
                              (unless (kargu-nonempty patch)
                                "ERROR: patch argument is required"))))
            (if failure (deliver failure)
              (kargu-diff-apply-patch patch (and callback #'deliver))))
        (error (deliver (format "ERROR: %s" (error-message-string err))))))))

(defconst kargu-diff--tool-specs
  (list
   (list
    "edit_file"
    "Replace an exact unique block in an existing file. Read the relevant lines first, then supply old_string with enough surrounding text to be unique and new_string. Prefer structural editing when available. Changes follow the active review policy and retain rollback snapshots. Verify with available diagnostics and project tests."
    '(("type" . "object")
      ("properties" . (("file_path" . (("type" . "string")
                                       ("description" . "Absolute or project-relative path of the file to edit.")))
                       ("old_string" . (("type" . "string")
                                        ("description" . "The exact unique string to replace, copied from read_file without the line-number prefix.")))
                       ("new_string" . (("type" . "string")
                                        ("description" . "The replacement string.")))
                       ("reason" . (("type" . "string")
                                    ("description" . "One-sentence justification of the edit, shown to the human during review.")))))
      ("required" . ["file_path" "old_string" "new_string"]))
    #'kargu-diff--edit-file-tool)
   (list
    "write_file"
    "Write or rewrite a file completely. Overwrites the entire file with contents (or creates it if it does not exist). Note: for small, localized changes to an existing file, prefer edit_file to save tokens and avoid merge conflicts. Use write_file when replacing the entire file or creating a new file. The human reviews the proposal in ediff before it is saved."
    '(("type" . "object")
      ("properties" . (("file_path" . (("type" . "string")
                                       ("description" . "Absolute or project-relative path of the file to write or create.")))
                       ("contents" . (("type" . "string")
                                      ("description" . "Complete contents of the file.")))
                       ("reason" . (("type" . "string")
                                    ("description" . "One-sentence justification, shown during review.")))))
      ("required" . ["file_path" "contents"]))
    #'kargu-diff--write-file-tool)
   (list
    "apply_patch"
    "Apply a multi-file standard Unified Diff patch in an isolated temporary workspace. Agent mode only.
Binary patches, renames/copies and file mode changes are unsupported and rejected before writing.
Format:
--- a/path/to/existing.ext
+++ b/path/to/existing.ext
@@ -1,3 +1,3 @@
 context
-old line
+new line
--- /dev/null
+++ b/path/to/new_file.ext
@@ -0,0 +1,2 @@
+line1
+line2
--- a/path/to/deleted.ext
+++ /dev/null
@@ -1,1 +0,0 @@
-removed line"
    '(("type" . "object")
      ("properties" . (("patch" . (("type" . "string")
                                   ("description" . "Standard Unified Diff patch text (--- a/file, +++ b/file, @@ -L,C +L,C @@).")))))
      ("required" . ["patch"]))
    #'kargu-diff--apply-patch-tool))
  "Tool schemas and executors for diff operations.")

(defconst kargu-diff--tool-aliases
  '(("edit" . "edit_file")
    ("write" . "write_file")
    ("patch" . "apply_patch"))
  "Aliases for the diff tools.")

(defun kargu-diff-register-tools ()
  "Register the diff tools and their aliases."
  (kargu-register-tools kargu-diff--tool-specs kargu-diff--tool-aliases))

;; Apply review_mode from TOML config if present
(when (fboundp 'kargu--config-plist)
  (when-let* ((mode-str (plist-get (kargu--config-plist) :review-mode))
              ((stringp mode-str)))
    (let ((m (intern (downcase (string-trim mode-str)))))
      (when (memq m '(auto blocking async))
        (setq kargu-diff-review-mode m)))))

(defun kargu-diff-query-changes (query)
  "Answer change-evidence QUERY using this adapter's existing records."
  (let ((value (kargu-change-query-value query)))
    (pcase (kargu-change-query-operation query)
      (:available t)
      (:pending (kargu-diff-changed-files))
      (:modified (kargu-diff-run-modified-files))
      (:capture (kargu-diff-pending-change value))
      (:baseline (kargu-diff-change-baseline value))
      (:consume (kargu-diff-consume-change value))
      (:consume-file (kargu-diff-consume-file value))
      (:reset (kargu-diff-reset-run-files))
      (:abort (kargu-diff-abort-all-sessions)))))

(defun kargu-diff-submit-edit (request)
  "Apply guarded edit REQUEST, preserving review and rollback semantics."
  (let ((callback (kargu-edit-request-callback request))
        (path (kargu-edit-request-path request))
        (content (kargu-edit-request-content request)))
    (if-let* ((blocked (kargu-diff--mutating-disabled "edit_by_lsp")))
        (if callback (funcall callback blocked) blocked)
      (if callback
          (kargu-diff-apply-proposal
           path content (lambda (outcome)
                          (funcall callback (kargu-diff--describe outcome))))
        (kargu-diff--describe (kargu-diff-apply-proposal path content))))))

(defun kargu-diff-prepare-execution (context)
  "Attach only CONTEXT's session edit service, retaining its undo snapshots."
  (with-current-buffer (kargu-execution-origin context)
    (let ((session (kargu-execution-session context)))
      (unless (and (eq (car kargu-diff--execution-service) session)
                   (not (kargu-edit-service-closed-p (cdr kargu-diff--execution-service))))
        (when (cdr kargu-diff--execution-service)
          (kargu-edit-service-close (cdr kargu-diff--execution-service)))
        (setq kargu-diff--execution-service
              (cons session (kargu-edit-service-create
                             :root (kargu-execution-root context)
                             :review-mode kargu-diff-review-mode :auto-save kargu-diff-auto-save))))
      (let ((service (cdr kargu-diff--execution-service))
            (previous (kargu-execution-enter context)))
        (setf (kargu-execution-enter context)
              (lambda (function args)
                (kargu-diff-with-service service
                                         (if previous (funcall previous function args)
                                           (apply function args)))))))))

(defun kargu-diff-install ()
  "Attach editing and evidence providers at application composition."
  (advice-add 'kargu-query-changes :override #'kargu-diff-query-changes)
  (advice-add 'kargu-edit-submit :override #'kargu-diff-submit-edit)
  (advice-add 'kargu-execution-prepare :after #'kargu-diff-prepare-execution)
  (add-hook 'kargu-session-before-replace-hook #'kargu-diff-retire-session)
  (advice-add 'kargu-edit-submit-plan :override #'kargu-diff-submit-plan))

(defun kargu-diff-retire-session (session)
  "Close only the edit service captured by retiring SESSION in this buffer."
  (when (eq (car kargu-diff--execution-service) session)
    (when-let* ((service (cdr kargu-diff--execution-service)))
      (kargu-diff-with-service service (kargu-diff-abort-all-sessions service))
      (kargu-edit-service-close service)
      (setq kargu-diff--execution-service nil))))

(defun kargu/tools/diff-unload-function ()
  "Refuse unloading an active adapter or one retaining recoverable edits."
  (when (or (and (fboundp 'kargu-loop-running-p) (kargu-loop-running-p))
            (kargu-diff-snapshot-paths) (kargu-diff-changed-files)
            (> (hash-table-count (kargu-diff--service-reviews)) 0)
            (seq-some (lambda (spec) (kargu-find-tool (car spec)))
                      kargu-diff--tool-specs))
    (user-error "Kargu: stop, resolve edits/reviews and unregister diff tools before unloading"))
  (advice-remove 'kargu-query-changes #'kargu-diff-query-changes)
  (advice-remove 'kargu-edit-submit #'kargu-diff-submit-edit)
  (advice-remove 'kargu-execution-prepare #'kargu-diff-prepare-execution)
  (remove-hook 'kargu-session-before-replace-hook #'kargu-diff-retire-session)
  (advice-remove 'kargu-edit-submit-plan #'kargu-diff-submit-plan)
  nil)

(provide 'kargu/tools/diff)

;;; diff.el ends here
