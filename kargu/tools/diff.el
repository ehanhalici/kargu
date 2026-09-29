;;; kargu/tools/diff.el --- Shadow buffers, ediff, rollback -*- lexical-binding: t; -*-

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
(require 'ediff)

(require 'kargu/core)
(require 'kargu/contract)
(require 'kargu/state/selectors)
(require 'kargu/api)
(require 'kargu/permission)

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

(defcustom kargu-diff-read-max-chars 15000
  "Character cap for the `read_file' tool result.
The text fed back to the model is additionally capped by
`kargu-tool-output-limit'."
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

(require 'kargu/tools/diff/track)
(require 'kargu/tools/diff/stage)
(require 'kargu/tools/diff/review)

;;;; File reading (companion tool) ----------------------------------------

(defun kargu-diff--format-numbered-lines (lines from to has-window)
  "Format LINES from 1-based indices FROM to TO.
Prefix each line with line number.  If HAS-WINDOW is nil and output
exceeds `kargu-diff-read-max-chars', truncate the output.
Returns a cons cell `(BODY . TRUNCATED-P)'."
  (let* ((picked (cl-subseq lines (1- from) to))
         (n from)
         (numbered
          (mapcar (lambda (line)
                    (prog1 (format "%d | %s" n line)
                      (setq n (1+ n))))
                  picked))
         (body (string-join numbered "\n"))
         (truncated (and (not has-window)
                         (> (length body) kargu-diff-read-max-chars)))
         (final-body (if truncated
                         (concat (substring body 0 kargu-diff-read-max-chars)
                                 "\n... [truncated; use from_line/to_line to read specific sections]")
                       body)))
    (cons final-body truncated)))

(defun kargu-diff--resolve-read-target (file-path)
  "Resolve FILE-PATH to (PATH . TEXT).
Signals an error if file does not exist or looks binary."
  (let* ((live-buf (and (stringp file-path)
                        (string-match-p "\\`\\*kargu-output-[0-9]+\\*\\'" file-path)
                        (get-buffer file-path)))
         (is-buf (and live-buf (buffer-live-p live-buf)))
         (path (if is-buf file-path (kargu-permission-resolve file-path "file"))))
    (if (and (not is-buf) (not (file-exists-p path)))
        (error (concat "No such file: '%s'\n"
                       "  - Attempted file: '%s'\n"
                       "  - Allowed project root: '%s'\n"
                       "  - Reason: The file does not exist within the permitted workspace boundary.\n"
                       "  - Guidance: Use `find_files' or `list_files' to locate existing files inside '%s', or use `write_file' if you intend to create a new file.")
               path file-path (kargu-permission-project-root) (kargu-permission-project-root))
      (let ((text (if is-buf
                      (with-current-buffer live-buf (buffer-string))
                    (with-temp-buffer
                      (insert-file-contents path)
                      (buffer-string)))))
        (when (cl-position 0 (substring text 0 (min 1000 (length text))))
          (error "%s looks like a binary file; read_file only serves text" path))
        (cons path text)))))

(defun kargu-diff--validate-read-bounds (from to total)
  "Validate that FROM and TO are within bounds of TOTAL lines."
  (when (> from total)
    (error "from_line (%d) exceeds file line count (%d)" from total))
  (when (< to from)
    (error "to_line (%d) is before from_line (%d)" to from)))

(defun kargu-diff-read-file (file-path &optional from-line to-line)
  "Return a model-oriented dump of FILE-PATH.
FROM-LINE and TO-LINE (1-based, inclusive) select a line window;
without them the whole file is served, capped at
`kargu-diff-read-max-chars'.  Each served line is prefixed with
its 1-based file line number (`12 | ...') so the model can copy
an exact `old_string' without the prefix."
  (kargu-contract-assert #'kargu-contract-filepath-p file-path
                         "FILE-PATH must be a valid file path string: %S" file-path)
  (let* ((target (kargu-diff--resolve-read-target file-path))
         (path (car target))
         (text (cdr target))
         (lines (split-string text "\n"))
         (total (max 1 (length lines)))
         (has-window (or from-line to-line))
         (from (max 1 (or (kargu-diff--to-int from-line) 1)))
         (to (min (or (kargu-diff--to-int to-line) total) total)))
    (kargu-diff--validate-read-bounds from to total)
    (let* ((formatted (kargu-diff--format-numbered-lines lines from to has-window))
           (body (car formatted))
           (truncated (cdr formatted)))
      (format "(file %s, lines %d-%d of %d%s)\n%s"
              path from to total
              (if truncated
                  (format ", capped at %d chars"
                          kargu-diff-read-max-chars)
                "")
              body))))

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
  "Executor for the `edit_file' tool: unique replace, stage, review."
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
  "Executor for the `write_file' tool: create or overwrite a file via ediff."
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

(defun kargu-diff--parse-patch-lines (lines)
  "Parse patch LINES into structured operations.
Returns a list of plists with keys :type, :file, :lines."
  (let* ((ops nil)
        (curr-type nil)
        (curr-file nil)
        (curr-lines nil)
        (flush-op
         (lambda ()
           (when (and curr-type curr-file)
             (push (list :type curr-type :file curr-file :lines (nreverse curr-lines)) ops)
             (setq curr-type nil
                   curr-file nil
                   curr-lines nil)))))
    (dolist (raw lines)
      (let ((line (string-trim-right raw)))
        (cond
         ((or (string-prefix-p "*** Begin Patch" line)
              (string-prefix-p "*** End Patch" line))
          nil)
         ((string-prefix-p "*** Add File:" line)
          (funcall flush-op)
          (setq curr-type 'add
                curr-file (string-trim (substring line 13))))
         ((string-prefix-p "*** Update File:" line)
          (funcall flush-op)
          (setq curr-type 'update
                curr-file (string-trim (substring line 16))))
         ((string-prefix-p "*** Delete File:" line)
          (funcall flush-op)
          (setq curr-type 'delete
                curr-file (string-trim (substring line 16))))
         (curr-type
          (push raw curr-lines)))))
    (funcall flush-op)
    (nreverse ops)))

(defun kargu-diff--hunk-line-hint (header)
  "Line number an `@@' HEADER names, or nil.
`@@ -A,B +C,D @@' names A, the line a pure addition follows (0 is the top of
the file); a bare `@@ N' names N."
  (cond
   ((string-match "\\`@@ -\\([0-9]+\\)" header)
    (string-to-number (match-string 1 header)))
   ((string-match "\\`@@ \\([0-9]+\\)\\_>" header)
    (string-to-number (match-string 1 header)))))

(defun kargu-diff--split-update-hunks (op-lines)
  "Group OP-LINES into hunks demarcated by @@ markers.
Each hunk is (LINE-HINT . LINES), LINE-HINT being what its header names."
  (let ((hunks nil) (curr-hunk nil) (hint nil))
    (cl-flet ((flush () (when curr-hunk (push (cons hint (nreverse curr-hunk)) hunks))
                (setq curr-hunk nil hint nil)))
      (dolist (l op-lines)
        (cond
         ((string-prefix-p "*** Move to:" l) nil)
         ((string-prefix-p "@@" l)
          (flush)
          (setq hint (kargu-diff--hunk-line-hint l)))
         (t (push l curr-hunk))))
      (flush))
    (nreverse hunks)))

(defun kargu-diff--hunk-blocks (hunk-lines)
  "Extract (OLD-BLOCK . NEW-BLOCK) from HUNK-LINES."
  (cl-flet ((block-of (drop keep)
              (string-join
               (delq nil
                     (mapcar (lambda (l)
                               (cond
                                ((string-prefix-p drop l) nil)
                                ((or (string-prefix-p keep l) (string-prefix-p " " l))
                                 (substring l 1))
                                (t l)))
                             hunk-lines))
               "\n")))
    (cons (block-of "+" "-") (block-of "-" "+"))))

(defun kargu-diff--insert-after-line (text new line)
  "TEXT with NEW inserted after its LINE-th line (0 is the top)."
  (let* ((lines (split-string text "\n"))
         (line (min line (length lines))))
    (string-join (append (seq-take lines line) (list new) (seq-drop lines line))
                 "\n")))

(defun kargu-diff--apply-hunk (text old new rel &optional line-hint)
  "Replace the single occurrence of OLD in TEXT with NEW.
Zero matches and several matches are errors.  REL names the file in the
error.  An empty OLD is a pure addition: NEW goes after LINE-HINT when
the hunk header named one, else at the end."
  (cond
   ((and (string-empty-p old) line-hint)
    (kargu-diff--insert-after-line text new line-hint))
   ((string-empty-p old)
    (concat text (if (string-suffix-p "\n" text) "" "\n") new))
   (t
    (let ((matches (kargu-diff--count-literal text old)))
      (cond
       ((= matches 1) (kargu-diff--replace-first text old new))
       ((= matches 0)
        (error "Hunk failed to match in %s: %s"
               rel (truncate-string-to-width old 60)))
       (t
        (error "Hunk matched %d times in %s; refusing to guess"
               matches rel)))))))

(defun kargu-diff--update-text (orig rel op-lines)
  "ORIG with the hunks of OP-LINES applied; REL names the file in errors."
  (let ((text orig))
    (dolist (hunk (kargu-diff--split-update-hunks op-lines))
      (let ((blocks (kargu-diff--hunk-blocks (cdr hunk))))
        (setq text (kargu-diff--apply-hunk text (car blocks) (cdr blocks)
                                           rel (car hunk)))))
    text))

;;;; Patch: plan first, then write ----------------------------------------

(defun kargu-diff--patch-current (state file)
  "Text of FILE as the patch has left it so far, or nil when it is absent.
STATE maps a file to (:text TEXT) or (:deleted TEXT)."
  (let ((entry (gethash file state)))
    (cond
     ((null entry) (and (file-exists-p file) (or (kargu-diff--file-text file) "")))
     ((eq (car entry) :deleted) nil)
     (t (cadr entry)))))

(defun kargu-diff--plan-patch-op (state op)
  "Fold OP into STATE without touching any file; return its summary line.
Signals when OP cannot apply, so a bad patch changes nothing."
  (let* ((type (plist-get op :type))
         (rel (plist-get op :file))
         (file (kargu-permission-resolve rel "file"))
         (lines (plist-get op :lines))
         (current (kargu-diff--patch-current state file)))
    (pcase type
      ('add
       (when current
         (error "Cannot add %s: it already exists; use Update File" rel))
       (let ((content-lines (mapcar (lambda (l) (if (string-prefix-p "+" l) (substring l 1) l))
                                    lines)))
         (puthash file (list :text (concat (string-join content-lines "\n") "\n")) state)
         (format "Added %s (%d lines)" rel (length content-lines))))
      ('update
       (unless current
         (error "Cannot update %s: no such file" rel))
       (puthash file (list :text (kargu-diff--update-text current rel lines)) state)
       (format "Updated %s" rel))
      ('delete
       (unless current
         (error "Cannot delete %s: no such file" rel))
       (unless (eq kargu-diff-review-mode 'auto)
         (error "Deleting %s through a patch is only supported in `auto' review mode; delete it with the bash tool, which asks for approval" rel))
       (puthash file (list :deleted current) state)
       (format "Deleted %s" rel)))))

(defun kargu-diff--delete-file (file original)
  "Delete FILE, keeping ORIGINAL as its rollback snapshot."
  (puthash file (cons (list :content original :created-new nil :at (current-time))
                      (gethash file kargu-diff--snapshots))
           kargu-diff--snapshots)
  (when-let* ((buf (find-buffer-visiting file)))
    (with-current-buffer buf (set-buffer-modified-p nil))
    (kill-buffer buf))
  (delete-file file)
  (puthash file (list :status :applied-full :saved t
                      :at (format-time-string "%H:%M:%S"))
           kargu-diff--changed)
  (when (boundp 'kargu-diff--run-modified-files)
    (cl-pushnew file kargu-diff--run-modified-files :test #'equal)))

(defun kargu-diff--commit-patch (state)
  "Write every change in STATE through the proposal pipeline."
  (maphash (lambda (file entry)
             (if (eq (car entry) :deleted)
                 (kargu-diff--delete-file file (cadr entry))
               (kargu-diff-apply-proposal file (cadr entry))))
           state))

(defun kargu-diff-apply-patch (patch-text)
  "Parse and apply PATCH-TEXT supporting '*** Add File: <path>',
'*** Update File: <path>', and '*** Delete File: <path>' within optional
'*** Begin Patch' and '*** End Patch' envelopes.
The whole patch is checked first; if any operation cannot apply, no file
is touched.  Edits then go through the proposal and rollback pipeline.
Returns a formatted summary of applied changes."
  (kargu-contract-assert #'kargu-contract-non-empty-string-p patch-text
                         "PATCH-TEXT must be a non-empty string: %S" patch-text)
  (let* ((ops (kargu-diff--parse-patch-lines (split-string (string-trim patch-text) "\n")))
         (state (make-hash-table :test #'equal)))
    (unless ops
      (error "No valid patch operations found (expected '*** Add File:', '*** Update File:', or '*** Delete File:')"))
    (let ((results (mapcar (lambda (op) (kargu-diff--plan-patch-op state op)) ops)))
      (kargu-diff--commit-patch state)
      (format "Patch successfully applied to %d file(s):\n  • %s"
              (length results) (string-join results "\n  • ")))))

(defun kargu-diff--apply-patch-tool (args)
  "Executor for the `apply_patch' tool."
  (or (kargu-diff--mutating-disabled "apply_patch")
      (let ((patch (kargu--tool-arg args "patch" "diff" "content")))
        (if (not (kargu-nonempty patch))
            "ERROR: patch argument is required"
          (condition-case-unless-debug err
              (kargu-diff-apply-patch patch)
            (error (format "ERROR: %s" (error-message-string err))))))))

(defun kargu-diff-register-tools ()
  "Register the diff, edit, write, read and apply_patch tools."
  (kargu-register-tool
   "read_file"
   "Read a source file with numbered lines (\"12 | code\"). Before reading a large code file, prefer 'read_file_symbols' (outline) to see its structure or 'read_symbol' to inspect a specific function/struct. Requires 'file_path'. NEVER pass search patterns or regex here. Use from_line/to_line (or limit) to page through specific sections, or for non-code files (config, markdown, yaml)."
   '(("type" . "object")
     ("properties" . (("file_path" . (("type" . "string")
                                       ("description" . "Absolute or project-relative path of the file (or output buffer) to read. Must be a valid file path, NOT a search pattern or regex.")))
                      ("from_line" . (("type" . "integer")
                                       ("description" . "First 1-based line to return (inclusive).")))
                      ("to_line" . (("type" . "integer")
                                     ("description" . "Last 1-based line to return (inclusive).")))
                      ("limit" . (("type" . "integer")
                                   ("description" . "Maximum number of lines to return from from_line.")))))
     ("required" . ["file_path"]))
   (lambda (args)
     (let* ((path (kargu--tool-file-path args))
            (from (or (kargu--tool-arg args "from_line" "fromLine")
                      (kargu--tool-arg args "offset")))
            (limit (kargu--tool-arg args "limit"))
            (to (or (kargu--tool-arg args "to_line" "toLine")
                    (and from limit
                         (let ((f (kargu-diff--to-int from))
                               (n (kargu-diff--to-int limit)))
                            (and f n (+ f n -1)))))))
       (if (not (kargu-nonempty path))
           (kargu--tool-missing-file-path args)
         (condition-case-unless-debug err
             (kargu-diff-read-file path from to)
           (error (format "ERROR: %s" (error-message-string err))))))))
  (kargu-register-tool
   "edit_file"
   "Replace an exact unique block of text in an existing file. NOTE: For modifying existing code definitions (functions, classes, structs, methods, types), ALWAYS PREFER 'edit_by_lsp' instead. Use edit_file only as a fallback for non-code files (markdown, configs) or text outside defined symbols. Read the file first with read_file, then pass the exact old_string (include enough surrounding lines to make it unique) and the new_string replacement. The human reviews the change in ediff (b accepts a hunk, a keeps the original). After an accepted edit, immediately call lsp_diagnostics on the file."
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
  (kargu-register-tool
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
  (kargu-register-tool
   "apply_patch"
   "Apply a multi-file unified patch across multiple files in a single tool call. Agent mode only.
Format:
*** Begin Patch
*** Add File: path/to/file.ext
+line1
*** Update File: path/to/file.ext
@@
 context
-old line
+new line
*** Delete File: path/to/file.ext
*** End Patch"
   '(("type" . "object")
     ("properties" . (("patch" . (("type" . "string")
                                   ("description" . "Complete unified patch text with file envelopes.")))))
     ("required" . ["patch"]))
   #'kargu-diff--apply-patch-tool)
  (kargu-register-tool-alias "read" "read_file")
  (kargu-register-tool-alias "edit" "edit_file")
  (kargu-register-tool-alias "write" "write_file")
  (kargu-register-tool-alias "patch" "apply_patch"))

(kargu-diff-register-tools)

;; Apply review_mode from TOML config if present
(when (fboundp 'kargu--config-plist)
  (when-let* ((mode-str (plist-get (kargu--config-plist) :review-mode)))
    (let ((m (intern (downcase (string-trim mode-str)))))
      (when (memq m '(auto blocking async))
        (setq kargu-diff-review-mode m)))))

(provide 'kargu/tools/diff)

;;; kargu/tools/diff.el ends here
