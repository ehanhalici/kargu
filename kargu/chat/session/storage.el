;;; storage.el --- Explicit project-scoped session storage -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Session storage options, the session identifier rule and the editor's
;; view of storage paths.  Native persistence owns every read and write;
;; nothing here touches a session file's contents.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'rx)
(require 'kargu/core)
(require 'kargu/json)
(require 'kargu/permission/guards)

(defgroup kargu-session nil
  "Persistent project-scoped chat sessions for kargu."
  :group 'kargu :prefix "kargu-session-")

(defcustom kargu-sessions-directory
  (expand-file-name "sessions"
                    (or (and (getenv "XDG_DATA_HOME")
                             (not (string-empty-p (getenv "XDG_DATA_HOME")))
                             (expand-file-name "kargu" (getenv "XDG_DATA_HOME")))
                        (locate-user-emacs-file "kargu")))
  "Central directory where chat sessions are stored across restarts."
  :type 'directory :group 'kargu-session)

(defcustom kargu-session-storage-location 'central
  "Where new session records are saved and restored.
`central' uses `kargu-sessions-directory'; `project' explicitly opts into
.kargu/sessions inside each project.  Existing local directories do not
change the default.  No Git ignore or index files are modified."
  :type '(choice (const central) (const project)) :group 'kargu-session)

(defcustom kargu-session-max-file-bytes (* 16 1024 1024)
  "Maximum serialized session file size accepted for reading and writing."
  :type 'natnum :group 'kargu-session)

(defun kargu-session-storage--project-key (root)
  "Return a deterministic filesystem slug for canonical project ROOT."
  (let* ((canonical (file-truename (directory-file-name root)))
         (name (file-name-nondirectory canonical))
         (clean (replace-regexp-in-string
                 (rx (not (any "a-zA-Z0-9._-"))) "_" (if (string-empty-p name) "root" name))))
    (format "%s-%s" clean (substring (secure-hash 'sha1 canonical) 0 8))))

(defun kargu-session-storage--assert-id (id)
  "Return ID when it is a safe filename component; otherwise signal.
This is the core's session identifier rule: ASCII, at most 128 bytes,
alphanumeric first, then alphanumerics, `_', `.' or `-', and no `..'."
  (unless (and (stringp id)
               (<= 1 (string-bytes id) 128)
               (let ((case-fold-search nil))
                 (string-match-p (rx bos (any "a-zA-Z0-9") (* (any "a-zA-Z0-9_.-")) eos) id))
               (not (string-search ".." id)))
    (user-error "Kargu: invalid session identifier; use a plain filename without path separators"))
  id)

(defun kargu-session-storage--within (path root)
  "Return PATH if its real location stays within ROOT; otherwise signal."
  (unless (kargu-permission-within-project-p path root)
    (user-error "Kargu: session path escapes its storage boundary through a symlink"))
  path)

(defun kargu-session-storage--local-directory (root)
  "Return the contained local session directory for explicit project ROOT."
  (kargu-session-storage--within (expand-file-name ".kargu/sessions/" root) root))

(defun kargu-session-storage-directory (root)
  "Return the storage directory for explicit project ROOT without creating it."
  (pcase kargu-session-storage-location
    ('project (kargu-session-storage--local-directory root))
    ('central
     (kargu-session-storage--within
      (file-name-as-directory
       (expand-file-name (kargu-session-storage--project-key root) kargu-sessions-directory))
      kargu-sessions-directory))
    (_ (user-error "Kargu: invalid session storage location"))))

(defun kargu-session-storage-file (id root)
  "Return a contained JSON path for safe session ID in project ROOT."
  (let ((directory (kargu-session-storage-directory root)))
    (kargu-session-storage--within
     (expand-file-name (concat (kargu-session-storage--assert-id id) ".json") directory)
     directory)))

(defun kargu-session-storage-local-ids (root)
  "List safe local session IDs under explicit project ROOT without reading JSON."
  (let ((directory (kargu-session-storage--local-directory root)) ids)
    (when (file-directory-p directory)
      (dolist (file (directory-files directory t (rx ".json" eos)))
        (condition-case nil
            (when (and (file-regular-p file) (kargu-permission-within-project-p file directory))
              (push (kargu-session-storage--assert-id (file-name-base file)) ids))
          (user-error nil))))
    (nreverse ids)))

(defun kargu-session-metadata-p (record)
  "Return non-nil when RECORD is a metadata summary without conversation."
  (and (or (consp record) (hash-table-p record))
       (stringp (kargu-aget record "id"))
       (natnump (kargu-aget record "message_count"))
       (null (kargu-aget record "messages"))
       (null (kargu-aget record "transcript"))))

(provide 'kargu/chat/session/storage)
;;; storage.el ends here
