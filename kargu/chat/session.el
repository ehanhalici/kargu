;;; session.el --- Persistent project-scoped chat sessions -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Project-scoped persistent chat sessions across Emacs and Kargu restarts.
;; Saves conversation history, metadata, token usage, and transcripts as JSON.
;; Automatically restores the latest chat session when reopening a project.
;; Public: `kargu-session-save', `kargu-session-load', `kargu-session-list',
;; `kargu-session-delete', `kargu-chat-sessions', `kargu-session-auto-save-all'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'kargu/core)
(require 'kargu/async)
(require 'kargu/json)
(require 'kargu/history)
(require 'kargu/permission/guards)
(require 'kargu/tools/process)
(require 'kargu/chat/routing)
(require 'kargu/chat/session/storage)
(require 'kargu/chat/session/validate)
(require 'kargu/chat/session/restore)
(require 'kargu/bridge/session)

(defvar-local kargu-session--list-generation 0
  "Monotonic generation counter for asynchronous session listings.")

(defvar-local kargu-session--list-task nil
  "Active asynchronous session listing task owned by this buffer.")

(declare-function kargu-state-mode "kargu/state/selectors" ())
(declare-function kargu-set-mode "kargu/core" (mode))
(declare-function kargu--provider-name "kargu/config/key" ())
(declare-function kargu--model "kargu/config/key" ())
(declare-function kargu-chat--ensure-idle-prompt "kargu/chat/prompt" ())
(declare-function kargu-chat-list-buffers "kargu/chat" ())
(declare-function kargu-loop-running-p "kargu/loop" ())

(defcustom kargu-session-auto-save t
  "When non-nil, chat sessions are automatically saved after each turn."
  :type 'boolean
  :group 'kargu-session)

(defcustom kargu-session-auto-save-debounce 0.5
  "Seconds to debounce auto-saving chat sessions."
  :type 'number
  :group 'kargu-session)

(defcustom kargu-session-auto-restore t
  "When non-nil, opening chat in a project restores its latest saved session."
  :type 'boolean
  :group 'kargu-session)

(defvar-local kargu-session--auto-save-timer nil
  "Debounce timer for auto-saving the current buffer's session.")

;;;; Buffer-local session state -------------------------------------------

(defvar-local kargu-chat--session-id nil
  "Session identifier associated with this chat buffer.")

(defvar-local kargu-chat--session-title nil
  "Human-readable title of this chat session.")

(defvar-local kargu-chat--session-revision 0
  "Last storage revision native persistence confirmed for this chat, or 0.
A save sends it as the expected revision, so a stale writer is refused.")

(defun kargu-chat-session-id (&optional buffer)
  "Return the session identity belonging to BUFFER, defaulting to current."
  (buffer-local-value 'kargu-chat--session-id (or buffer (current-buffer))))

(defun kargu-chat--explicit-selection (value)
  "Return VALUE when it is a non-blank string, otherwise nil."
  (and (stringp value)
       (let ((s (string-trim value)))
         (unless (string-empty-p s) s))))

(defun kargu-session-cancel-listing (&optional buffer)
  "Cancel any pending session listing in BUFFER, defaulting to current."
  (let ((buf (or buffer (current-buffer))))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (cl-incf kargu-session--list-generation)
        (when kargu-session--list-task
          (kargu-async-cancel kargu-session--list-task)
          (setq kargu-session--list-task nil))))))

(defun kargu-chat-session-reset ()
  "Clear the current chat's session view after application reset completes."
  (kargu-session-cancel-listing)
  (when (derived-mode-p 'kargu-chat-mode)
    (setq kargu-chat--session-id nil
          kargu-chat--session-revision 0)))

(defun kargu/chat/session-unload-function ()
  "Detach this adapter's reset notification before unloading it."
  (remove-hook 'kargu-session-reset-hook #'kargu-chat-session-reset)
  nil)

;;;; Project paths & storage helpers --------------------------------------

(defun kargu-session-project-root (&optional buffer-or-dir)
  "Return the canonical project root for BUFFER-OR-DIR.
An explicit directory or a buffer's saved project root takes precedence
over the current workspace."
  (let* ((buffer (and (buffer-live-p buffer-or-dir) buffer-or-dir))
         (root (cond
                ((stringp buffer-or-dir) buffer-or-dir)
                ((and buffer
                      (buffer-local-value 'kargu-chat--project-root buffer)))
                (t (kargu-permission-project-root buffer)))))
    (file-name-as-directory (file-truename (expand-file-name root)))))

;;;; Serialization & Storage ---------------------------------------------

(defvar kargu-chat--output-marker)

(defun kargu-session--extract-transcript (buf)
  "Extract the read-only transcript text from BUF up to the output marker."
  (with-current-buffer buf
    (save-restriction
      (widen)
      (let ((end (if (and (boundp 'kargu-chat--output-marker)
                        (markerp kargu-chat--output-marker)
                        (eq (marker-buffer kargu-chat--output-marker) buf))
                   (marker-position kargu-chat--output-marker)
                 (point-max))))
      (if (> end (point-min))
          (buffer-substring-no-properties (point-min) end)
        "")))))

(defun kargu-session--derive-title (messages fallback)
  "Derive a short descriptive session title from MESSAGES or FALLBACK."
  (or (cl-some (lambda (m)
                 (when (equal (kargu-aget m "role") "user")
                   (let ((c (kargu-aget m "content")))
                     (when (and (stringp c) (not (string-empty-p (string-trim c))))
                       (truncate-string-to-width
                        (replace-regexp-in-string "[\r\n\t]+" " " (string-trim c))
                        60)))))
               messages)
      fallback
      "New Session"))

(cl-defun kargu-session--build-data
    (&key sid root title usage mode provider model effort transcript messages)
  "Build SID's record under ROOT with TITLE, USAGE, MODE and choices.
Store PROVIDER, MODEL, EFFORT, TRANSCRIPT and native MESSAGES."
  `(("schema_version" . ,kargu-session-schema-version)
    ("effort" . ,(kargu-session-encode-effort effort))
    ("id" . ,sid)
    ("project_root" . ,root)
    ("project_name" . ,(file-name-nondirectory (directory-file-name root)))
    ("title" . ,title)
    ("created_at" . ,(or (plist-get usage :started)
                         (format-time-string "%Y-%m-%d %H:%M:%S")))
    ("updated_at" . ,(format-time-string "%Y-%m-%d %H:%M:%S"))
    ("mode" . ,(symbol-name mode))
    ("provider" . ,(or provider ""))
    ("model" . ,(or model ""))
    ("requests" . ,(or (plist-get usage :requests-spent) (plist-get usage :requests) 0))
    ("tokens_in" . ,(plist-get usage :tokens-in))
    ("tokens_out" . ,(plist-get usage :tokens-out))
    ("tokens_spent" . ,(or (plist-get usage :tokens-spent)
                           (and (numberp (plist-get usage :tokens-in))
                                (numberp (plist-get usage :tokens-out))
                                (+ (plist-get usage :tokens-in) (plist-get usage :tokens-out)))))
    ("tokens_unknown" . ,(if (or (plist-get usage :tokens-unknown) (plist-get usage :tokens-unknown-p)) t :json-false))
    ("monetary_spent" . ,(or (plist-get usage :monetary-spent) 0))
    ("monetary_reserved" . ,(or (plist-get usage :monetary-reserved) 0))
    ("monetary_unknown" . ,(if (or (plist-get usage :monetary-unknown) (plist-get usage :monetary-unknown-p)) t :json-false))
    ("message_count" . ,(length (or messages '())))
    ("transcript" . ,transcript)
    ("messages" . ,(vconcat (or messages '())))))

(defun kargu-session-auto-save-debounce (&optional buffer)
  "Schedule an auto-save for BUFFER after the debounce delay.
The delay is `kargu-session-auto-save-debounce' seconds.  The target
buffer is captured lexically so the save never slips to another buffer."
  (when (and (bound-and-true-p kargu-session-auto-save)
             (fboundp 'kargu-session-save))
    (let ((target-buf (or buffer (current-buffer))))
      (when (and (bufferp target-buf) (buffer-live-p target-buf))
        (with-current-buffer target-buf
          (when (timerp kargu-session--auto-save-timer)
            (cancel-timer kargu-session--auto-save-timer)
            (setq kargu-session--auto-save-timer nil))
          (setq kargu-session--auto-save-timer
                (run-with-timer
                 kargu-session-auto-save-debounce nil
                 (lambda (b)
                   (when (buffer-live-p b)
                     (with-current-buffer b
                       (setq kargu-session--auto-save-timer nil)
                       (kargu-session-save b))))
                 target-buf)))))))

(defun kargu-session-save (&optional buffer callback)
  "Save the chat session of BUFFER (default: current) via native persistence.
Delivers result or error to optional CALLBACK (RESULT ERROR).
Native persistence owns the write; there is no local synchronous fallback."
  (let ((buf (or buffer (current-buffer))))
    (when (and (bufferp buf) (buffer-live-p buf))
      (with-current-buffer buf
        (let* ((root (kargu-session-project-root buf))
               (sid (or kargu-chat--session-id
                        (and (fboundp 'kargu-session-id) (kargu-session-id))
                        (format "kargu-%s" (format-time-string "%Y%m%d%H%M%S"))))
               (messages (kargu-history-snapshot))
               (transcript (kargu-session--extract-transcript buf))
               (title (or kargu-chat--session-title
                          (kargu-session--derive-title messages (buffer-name buf))))
               (mode-val (if (fboundp 'kargu-state-mode)
                             (kargu-state-mode)
                           'agent))
               (prov (or (kargu-selection-provider) ""))
               (mod (or (kargu-selection-model) ""))
               (usage (kargu-session-snapshot)))
          ;; Avoid creating records for completely empty untouched sessions
          (if (not (or (and messages (> (length messages) 0))
                       (> (length (string-trim transcript)) 30)))
              (when callback (funcall callback nil nil))
            (setq kargu-chat--session-id sid
                  kargu-chat--project-root root
                  kargu-chat--session-title title)
            (let* ((expected (if (natnump kargu-chat--session-revision)
                                 kargu-chat--session-revision
                               0))
                   (data (cons (cons "revision" (1+ expected))
                               (kargu-session--build-data
                                :sid sid :root root :title title :usage usage :mode mode-val
                                :provider prov :model mod
                                :effort (kargu-selection-effort-value (kargu-selection-context))
                                :transcript transcript :messages messages))))
              (kargu-bridge-session-scope
               buf
               (lambda (connection scope failure)
                 (if failure
                     (progn
                       (kargu-log 'warn "Native persistence bridge unavailable: %s" failure)
                       (when callback (funcall callback nil failure)))
                   (let ((params (kargu-bridge--object
                                  "scope" scope
                                  "session_id" sid
                                  "storage" (kargu-session--native-storage root)
                                  "expected_revision" expected
                                  "record" (kargu-json-record-wire data))))
                     (kargu-bridge-session-save
                      connection params
                      (lambda (result save-err)
                        (if save-err
                            (progn
                              (kargu-log 'warn "Native session save failed: %s" save-err)
                              (when callback (funcall callback nil save-err)))
                          (let ((saved (and (hash-table-p result) (gethash "revision" result))))
                            (when (and (natnump saved) (buffer-live-p buf))
                              (with-current-buffer buf
                                (when (equal kargu-chat--session-id sid)
                                  (setq kargu-chat--session-revision saved)))))
                          (kargu-log 'info "session saved: %s" sid)
                          (when callback (funcall callback result nil))))
                      buf)))
                (kargu-session-storage-file sid root))))))))))

(defun kargu-session--customized-directory ()
  "Return `kargu-sessions-directory' only when the user changed it."
  (let ((standard (car (get 'kargu-sessions-directory 'standard-value))))
    (unless (and standard
                 (equal (expand-file-name kargu-sessions-directory)
                        (expand-file-name (eval standard t))))
      (directory-file-name (expand-file-name kargu-sessions-directory)))))

(defun kargu-session--native-storage (root &optional location)
  "Return the native storage choice for project ROOT.
LOCATION overrides `kargu-session-storage-location'.  Only the location
choice, raw editor facts and an explicitly customized central directory
are sent; Rust derives the session directory and its project key, so no
request names the directory it writes."
  (let* ((location (or location kargu-session-storage-location))
         (central (eq location 'central)))
    (kargu-bridge--object
     "location" (pcase location
                  ('central "central")
                  ('project "project")
                  (_ (user-error "Kargu: invalid session storage location")))
     "project_root" (directory-file-name (expand-file-name root))
     "xdg_data_home" (or (getenv "XDG_DATA_HOME") :json-null)
     "user_emacs_directory" (expand-file-name user-emacs-directory)
     "sessions_directory" (or (and central (kargu-session--customized-directory))
                              :json-null))))

(defun kargu-session-list (&optional root)
  "Return list of saved session metadata alists for project ROOT, newest first."
  (kargu-session-storage-list-metadata (kargu-session-project-root root)))

(defun kargu-session--list-owner-valid-p (origin session root generation)
  "Return non-nil while ORIGIN still owns SESSION, ROOT and GENERATION."
  (and (buffer-live-p origin)
       (with-current-buffer origin
         (and (eq session (kargu-session-context))
              (= generation kargu-session--list-generation)
              (equal root (kargu-session-project-root origin))))))

(defun kargu-session--attach-list-cleanup (origin task)
  "Cancel TASK if ORIGIN buffer closes before session listing finishes."
  (let ((cancel (lambda () (kargu-async-cancel task))))
    (with-current-buffer origin
      (add-hook 'kill-buffer-hook cancel nil t))
    (kargu-async-add-cleanup
     task (lambda ()
            (when (buffer-live-p origin)
              (with-current-buffer origin
                (when (eq kargu-session--list-task task)
                  (setq kargu-session--list-task nil))
                (remove-hook 'kill-buffer-hook cancel t)))))))

(defun kargu-session-list-async (root callback &optional origin)
  "List session metadata for ROOT via native persistence, then call CALLBACK.
CALLBACK receives (SESSIONS ERROR) while ORIGIN remains on the same
session, project root and listing generation."
  (kargu-contract-assert #'functionp callback)
  (let* ((origin (or origin (current-buffer)))
         (canonical (kargu-session-project-root (or root origin))))
    (kargu-session-cancel-listing origin)
    (with-current-buffer origin
      (let* ((session (kargu-session-context))
             (generation kargu-session--list-generation)
             (kargu--loop-run nil)
             (valid-p (lambda ()
                        (kargu-session--list-owner-valid-p
                         origin session canonical generation)))
             (task (kargu-async-start
                    (lambda (sessions err)
                      (when (funcall valid-p)
                        (funcall callback sessions err)))
                    :valid-p valid-p)))
        (setq kargu-session--list-task task)
        (kargu-session--attach-list-cleanup origin task)
        (kargu-bridge-session-scope
         origin
         (lambda (connection scope failure)
           (cond
            ((not (kargu-async-pending-p task)))
            (failure
             (kargu-async-finish task nil (format "Native persistence unavailable: %s" failure)))
            (t
             (let ((params (kargu-bridge--object
                            "scope" scope
                            "storage" (kargu-session--native-storage canonical))))
               (kargu-bridge-session-list
                connection params
                (lambda (reply error-data)
                  (cond
                   ((not (kargu-async-pending-p task)))
                   (error-data
                    (kargu-async-finish task nil (format "Session listing failed: %s" error-data)))
                   (t
                    (let* ((sessions-vec (and (hash-table-p reply) (gethash "sessions" reply)))
                           (sessions (if (vectorp sessions-vec) (append sessions-vec nil) sessions-vec)))
                      (kargu-async-finish task (or sessions '()) nil)))))
                origin))))))
        task))))

;;;; Deserialization & Restoration ---------------------------------------

(defvar kargu-chat-buffer-name)
(declare-function kargu-chat-mode "kargu/chat" ())

(defun kargu-session--render-restored-transcript (transcript updated-at message-count)
  "Render TRANSCRIPT or banner into current buffer.
Uses UPDATED-AT and MESSAGE-COUNT for status banner."
  (if (and transcript (not (string-empty-p transcript)))
      (progn
        (insert (propertize transcript
                            'read-only t
                            'front-sticky t
                            'rear-nonsticky '(read-only face front-sticky)))
        (unless (eq (char-before) ?\n)
          (insert "\n"))
        (insert (propertize (format "— restored session from %s (%d messages) —\n\n"
                                    updated-at
                                    message-count)
                            'face 'font-lock-comment-face
                            'read-only t)))
    (insert (concat "kargu chat — type at the prompt; "
                    "C-c C-c sends, C-c C-k stops, C-c C-n new chat, C-c C-b switch chat.\n\n"))))

(defun kargu-session--native-call (origin method params callback)
  "Send persistence METHOD with PARAMS for ORIGIN's scope.
PARAMS is a function of the native scope returning the request object.
CALLBACK receives (RESULT ERROR) with ERROR a short string."
  (kargu-bridge-session-scope
   origin
   (lambda (connection scope failure)
     (if failure
         (funcall callback nil (format "Native persistence unavailable: %s" failure))
       (funcall method connection (funcall params scope)
                (lambda (result error)
                  (if error
                      (funcall callback nil (format "%s" error))
                    (funcall callback result nil))))))))

(defun kargu-session--native-load (session-id root callback)
  "Fetch SESSION-ID's record for project ROOT from native persistence.
CALLBACK receives (RECORD ERROR); the record never comes from a local read."
  (kargu-session-storage--assert-id session-id)
  (kargu-session--native-call
   nil #'kargu-bridge-session-load
   (lambda (scope)
     (kargu-bridge--object "scope" scope "session_id" session-id
                           "storage" (kargu-session--native-storage root)))
   (lambda (reply error)
     (let ((record (and (hash-table-p reply) (gethash "record" reply))))
       (cond
        (error (funcall callback nil (format "Session load failed: %s" error)))
        ((not (hash-table-p record)) (funcall callback nil "Session not found"))
        ((not (equal (gethash "id" record) session-id))
         (funcall callback nil "Session record does not match its identifier"))
        (t (funcall callback record nil)))))))

(defun kargu-session--restore-data (raw target-buffer root callback)
  "Validate RAW and restore it into TARGET-BUFFER for ROOT, then CALLBACK."
  (let* ((data (kargu-session-validate raw))
         (_id (kargu-session-storage--assert-id (kargu-aget data "id")))
         (buf (kargu-chat-restore-target root target-buffer)))
    (kargu-session-restore :data data :target buf :root root :callback callback)))

(cl-defun kargu-session-load (session-or-id &optional target-buffer root &key callback)
  "Restore SESSION-OR-ID into TARGET-BUFFER for project ROOT natively.
SESSION-OR-ID is full session data, listing metadata or an id string;
metadata and ids are fetched through native persistence.  ROOT is
authoritative; metadata cannot switch projects.  An active run must
finish before loading another session.  CALLBACK receives (BUFFER ERROR).
Return the buffer on immediate success, or an owned task while preparing."
  (when callback (kargu-contract-assert #'functionp callback))
  (kargu-selection-require-idle)
  (let ((root (kargu-session-project-root (or root target-buffer))))
    (if (and (or (consp session-or-id) (hash-table-p session-or-id))
             (not (kargu-session-metadata-p session-or-id)))
        (kargu-session--restore-data session-or-id target-buffer root callback)
      (let* ((session-id (if (stringp session-or-id) session-or-id
                           (kargu-aget session-or-id "id")))
             (report (lambda (buffer error)
                       (cond (callback (funcall callback buffer error))
                             (error (message "Kargu: %s" error)))))
             (task (kargu-async-start report)))
        (kargu-session--native-load
         session-id root
         (lambda (record error)
           (when (kargu-async-pending-p task)
             (if error
                 (kargu-async-finish task nil error)
               (condition-case err
                   (kargu-session--restore-data
                    record target-buffer root
                    (lambda (buffer failure) (kargu-async-finish task buffer failure)))
                 (error (kargu-async-finish task nil (error-message-string err))))))))
        task))))

(defun kargu-session--choose (root prompt callback)
  "List ROOT's sessions natively, read one with PROMPT, then CALLBACK its id."
  (kargu-session-list-async
   root
   (lambda (sessions error)
     (cond
      (error (message "Kargu: %s" error))
      ((null sessions) (message "kargu: no saved sessions for %s" root))
      (t (let* ((choices (mapcar (lambda (s)
                                   (cons (format "%s (%s - %s)"
                                                 (or (kargu-aget s "title") "Untitled")
                                                 (or (kargu-aget s "updated_at") "")
                                                 (or (kargu-aget s "id") ""))
                                         (kargu-aget s "id")))
                                 sessions))
                (choice (completing-read prompt choices nil t)))
           (funcall callback (cdr (assoc choice choices)))))))
   (and (derived-mode-p 'kargu-chat-mode) (current-buffer))))

(defun kargu-session-delete (session-id &optional root callback)
  "Delete saved SESSION-ID for project ROOT through native persistence.
Interactively, choose from the native listing.  CALLBACK receives
\(RESULT ERROR).  There is no local fallback writer: when native
persistence is unavailable the session stays on disk and the error is
reported."
  (interactive (list nil))
  (let ((canonical (kargu-session-project-root root)))
    (if (null session-id)
        (kargu-session--choose
         canonical "Delete kargu session: "
         (lambda (chosen) (when chosen (kargu-session-delete chosen canonical callback))))
      (kargu-session-storage--assert-id session-id)
      (kargu-session--native-call
       nil #'kargu-bridge-session-delete
       (lambda (scope)
         (kargu-bridge--object "scope" scope "session_id" session-id
                               "storage" (kargu-session--native-storage canonical)))
       (lambda (result error)
         (if error
             (let ((msg (format "Delete failed: %s" error)))
               (if callback (funcall callback nil msg) (message "kargu: %s" msg)))
           (message "kargu: deleted session %s" session-id)
           (when callback (funcall callback result nil))))))))

(defun kargu-session--choice-entry (session)
  "Return (LABEL . SESSION) pair for `completing-read' from metadata SESSION."
  (let* ((title (or (kargu-aget session "title") "Untitled"))
         (time (or (kargu-aget session "updated_at") ""))
         (mode (or (kargu-aget session "mode") "agent"))
         (cnt (kargu-aget session "message_count"))
         (msgs (kargu-aget session "messages"))
         (msg-count (cond ((natnump cnt) cnt)
                          ((vectorp msgs) (length msgs))
                          (t (length (or msgs '())))))
         (label (format "[%s] (%s, %d msgs) %s" time mode msg-count title)))
    (cons label session)))

(defun kargu-chat--present-sessions (proj-root sessions)
  "Prompt user to select and restore one of SESSIONS for PROJ-ROOT."
  (if (null sessions)
      (message "kargu: no saved sessions for %s" proj-root)
    (let* ((choices (mapcar #'kargu-session--choice-entry sessions))
           (prompt (format "Select session for %s: "
                           (file-name-nondirectory (directory-file-name proj-root))))
           (choice (completing-read prompt choices nil t))
           (selected (cdr (assoc choice choices))))
      (when selected
        (when (and (derived-mode-p 'kargu-chat-mode)
                   (equal proj-root (kargu-session-project-root (current-buffer))))
          (kargu-session-save (current-buffer)))
        (kargu-session-load
         (kargu-aget selected "id") nil proj-root
         :callback (lambda (buffer error)
                     (if error (message "Kargu: %s" error)
                       (pop-to-buffer-same-window buffer)
                       (message "kargu: loaded session '%s'"
                                (kargu-aget selected "title")))))))))

(defun kargu-chat-sessions (&optional root)
  "Interactively switch to a saved chat session for project ROOT."
  (interactive)
  (let ((proj-root (kargu-session-project-root root)))
    (kargu-session-list-async
     proj-root
     (lambda (sessions error)
       (if error
           (message "Kargu: %s" error)
         (kargu-chat--present-sessions proj-root sessions))))))

(defun kargu-session-auto-save-all ()
  "Save all active kargu chat buffers to disk."
  (when kargu-session-auto-save
    (when (fboundp 'kargu-chat-list-buffers)
      (dolist (buf (kargu-chat-list-buffers))
        (when (buffer-live-p buf)
          (ignore-errors
            (kargu-session-save buf)))))))

(defun kargu-session-import-local (session-id &optional root callback)
  "Copy local SESSION-ID from ROOT to central storage via native persistence.
Rust reads the project-local source, migrates it and writes the central
record; the source is retained and existing central records are never
overwritten.  ROOT defaults to the current chat's project, not any
project named by session metadata.  CALLBACK receives (RESULT ERROR)."
  (interactive
   (let* ((root (kargu-session-project-root))
          (ids (kargu-session-storage-local-ids root)))
     (unless ids (user-error "Kargu: no safe local session files found"))
     (list (completing-read "Import local session: " ids nil t) root)))
  (kargu-session-storage--assert-id session-id)
  (let ((proj-root (kargu-session-project-root root)))
    (kargu-session--native-call
     nil #'kargu-bridge-session-import
     (lambda (scope)
       (kargu-bridge--object
        "scope" scope
        "session_id" session-id
        "storage" (kargu-session--native-storage proj-root 'central)
        "source" (kargu-session--native-storage proj-root 'project)
        "collision" "override"))
     (lambda (result error)
       (if error
           (let ((msg (format "Import failed: %s" error)))
             (if callback (funcall callback nil msg) (message "kargu: %s" msg)))
         (message "Kargu: imported %s; the local source was retained" session-id)
         (when callback (funcall callback result nil)))))))

(add-hook 'kill-emacs-hook #'kargu-session-auto-save-all)

(provide 'kargu/chat/session)

;;; session.el ends here
