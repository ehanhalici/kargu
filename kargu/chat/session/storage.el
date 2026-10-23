;;; storage.el --- Explicit project-scoped session storage -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Storage is independent of chat buffers and always receives the project
;; root explicitly.  Central storage is the default; local records are
;; imported only on request and never removed or silently overwritten.

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

(defcustom kargu-session-list-max-files 500
  "Maximum number of session files inspected when listing a project."
  :type 'natnum :group 'kargu-session)

(defcustom kargu-session-list-max-total-bytes (* 64 1024 1024)
  "Maximum cumulative bytes read across session files during one listing."
  :type 'natnum :group 'kargu-session)

(defconst kargu-session-storage--temporary-prefix ".kargu-session-"
  "Prefix for private temporary files published by atomic rename.")

(defun kargu-session-storage--project-key (root)
  "Return a deterministic filesystem slug for canonical project ROOT."
  (let* ((canonical (file-truename (directory-file-name root)))
         (name (file-name-nondirectory canonical))
         (clean (replace-regexp-in-string
                 (rx (not (any "a-zA-Z0-9._-"))) "_" (if (string-empty-p name) "root" name))))
    (format "%s-%s" clean (substring (secure-hash 'sha1 canonical) 0 8))))

(defun kargu-session-storage--assert-id (id)
  "Return ID when it is a safe filename component; otherwise signal."
  (unless (and (stringp id)
               (string-match-p (rx bos (any alnum) (* (any alnum "_.-")) eos) id))
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

(defun kargu-session-storage--read (file)
  "Read a size-bounded JSON FILE without publishing chat state."
  (unless (file-readable-p file) (user-error "Kargu: session file is not readable"))
  (let ((size (file-attribute-size (file-attributes file))))
    (when (> size kargu-session-max-file-bytes)
      (user-error "Kargu: session file exceeds kargu-session-max-file-bytes")))
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file nil 0 (1+ kargu-session-max-file-bytes))
    (when (> (buffer-size) kargu-session-max-file-bytes)
      (user-error "Kargu: session file grew beyond its size limit"))
    (condition-case nil
        (kargu-json-decode (decode-coding-string (buffer-string) 'utf-8))
      (error (user-error "Kargu: invalid session JSON")))))

(defun kargu-session-storage-read (id root)
  "Read session ID under explicit project ROOT, or nil when it is absent."
  (let ((file (kargu-session-storage-file id root)))
    (when (file-readable-p file) (kargu-session-storage--read file))))

(cl-defun kargu-session-storage-write (id root data &key exclusive)
  "Atomically publish session DATA for ID under explicit project ROOT.
EXCLUSIVE refuses to replace any existing record.  New files are private;
the old record remains intact when encoding or writing fails."
  (let* ((file (kargu-session-storage-file id root))
         (directory (file-name-directory file))
         (text (kargu-json-encode-record data)))
    (when (> (string-bytes (encode-coding-string text 'utf-8)) kargu-session-max-file-bytes)
      (user-error "Kargu: session data exceeds kargu-session-max-file-bytes"))
    (make-directory directory t)
    (let ((temporary (make-temp-file (expand-file-name kargu-session-storage--temporary-prefix directory))))
      (unwind-protect
          (progn
            (let ((coding-system-for-write 'utf-8-unix))
              (write-region text nil temporary nil 'silent))
            (rename-file temporary file (not exclusive))
            file)
        (when (file-exists-p temporary) (delete-file temporary))))))

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

(defun kargu-session-storage-import-local (id root)
  "Copy local session ID under ROOT into central storage without overwriting.
The original remains untouched.  Refuse unsafe paths and mismatched IDs."
  (let* ((directory (kargu-session-storage--local-directory root))
         (source (kargu-session-storage--within
                  (expand-file-name (concat (kargu-session-storage--assert-id id) ".json") directory)
                  directory))
         (data (kargu-session-storage--read source))
         (kargu-session-storage-location 'central))
    (unless (equal (kargu-aget data "id") id)
      (user-error "Kargu: local session ID does not match its filename"))
    (kargu-session-storage-write id root data :exclusive t)))

(defun kargu-session-metadata-p (record)
  "Return non-nil when RECORD is a metadata summary without conversation."
  (and (or (consp record) (hash-table-p record))
       (stringp (kargu-aget record "id"))
       (natnump (kargu-aget record "message_count"))
       (null (kargu-aget record "messages"))
       (null (kargu-aget record "transcript"))))

(defun kargu-session-storage--string-field (decoded key fallback)
  "Return DECODED's string value at KEY, or FALLBACK when absent."
  (let ((val (gethash key decoded)))
    (if (stringp val) val fallback)))

(defun kargu-session-storage--natnum-field (decoded key)
  "Return DECODED's non-negative integer at KEY, or 0."
  (let ((val (gethash key decoded)))
    (if (natnump val) val 0)))

(defun kargu-session-storage--message-count (decoded)
  "Return message count from DECODED without retaining message bodies."
  (let ((cnt (gethash "message_count" decoded))
        (msgs (gethash "messages" decoded)))
    (cond ((natnump cnt) cnt)
          ((or (vectorp msgs) (listp msgs)) (length msgs))
          (t 0))))

(defun kargu-session-storage--extract-metadata (decoded expected-id root)
  "Extract metadata alist from DECODED when its id matches EXPECTED-ID in ROOT."
  (when (and (hash-table-p decoded)
             (equal (gethash "id" decoded) expected-id))
    (let ((effort (gethash "effort" decoded)))
      `(("schema_version" . ,(or (gethash "schema_version" decoded) 1))
        ("id" . ,expected-id)
        ("project_root" . ,(kargu-session-storage--string-field decoded "project_root" root))
        ("project_name" . ,(kargu-session-storage--string-field
                            decoded "project_name"
                            (file-name-nondirectory (directory-file-name root))))
        ("title" . ,(kargu-session-storage--string-field decoded "title" "Untitled"))
        ("created_at" . ,(kargu-session-storage--string-field decoded "created_at" ""))
        ("updated_at" . ,(kargu-session-storage--string-field decoded "updated_at" ""))
        ("mode" . ,(kargu-session-storage--string-field decoded "mode" "agent"))
        ("provider" . ,(kargu-session-storage--string-field decoded "provider" ""))
        ("model" . ,(kargu-session-storage--string-field decoded "model" ""))
        ("effort" . ,(and effort (kargu-json-to-record effort)))
        ("requests" . ,(kargu-session-storage--natnum-field decoded "requests"))
        ("tokens_in" . ,(kargu-session-storage--natnum-field decoded "tokens_in"))
        ("tokens_out" . ,(kargu-session-storage--natnum-field decoded "tokens_out"))
        ("message_count" . ,(kargu-session-storage--message-count decoded))))))

(defun kargu-session-storage-newer-p (a b)
  "Return non-nil when session metadata A precedes B deterministically."
  (let ((time-a (or (kargu-aget a "updated_at") ""))
        (time-b (or (kargu-aget b "updated_at") "")))
    (if (equal time-a time-b)
        (string> (or (kargu-aget a "id") "") (or (kargu-aget b "id") ""))
      (string> time-a time-b))))

(defun kargu-session-storage--candidate-entry (file directory)
  "Return (FILE ID SIZE MTIME) when FILE is a safe bounded session in DIRECTORY."
  (condition-case nil
      (when (and (file-regular-p file)
                 (file-readable-p file)
                 (kargu-permission-within-project-p file directory))
        (let* ((id (kargu-session-storage--assert-id (file-name-base file)))
               (attrs (file-attributes file))
               (size (and attrs (file-attribute-size attrs)))
               (mtime (and attrs (file-attribute-modification-time attrs))))
          (when (and (natnump size) (<= size kargu-session-max-file-bytes))
            (list file id size (float-time mtime)))))
    (error nil)))

(defun kargu-session-storage--candidate-files (directory)
  "Return bounded candidate session file entries in DIRECTORY, newest mtime first."
  (when (file-directory-p directory)
    (let (entries)
      (dolist (file (directory-files directory t (rx ".json" eos)))
        (when-let* ((entry (kargu-session-storage--candidate-entry file directory)))
          (push entry entries)))
      (seq-take
       (sort entries
             (lambda (a b)
               (if (= (nth 3 a) (nth 3 b))
                   (string> (nth 1 a) (nth 1 b))
                 (> (nth 3 a) (nth 3 b)))))
       kargu-session-list-max-files))))

(defun kargu-session-storage-list-metadata (root)
  "Return deterministic list of session metadata alists for canonical ROOT."
  (let* ((canonical (file-name-as-directory (file-truename (expand-file-name root))))
         (directory (kargu-session-storage-directory canonical))
         (candidates (kargu-session-storage--candidate-files directory))
         (remaining kargu-session-list-max-total-bytes)
         sessions)
    (dolist (entry candidates)
      (pcase-let ((`(,file ,id ,size ,_mtime) entry))
        (when (<= size remaining)
          (setq remaining (- remaining size))
          (condition-case err
              (when-let* ((decoded (kargu-session-storage--read file))
                          (meta (kargu-session-storage--extract-metadata
                                 decoded id canonical)))
                (push meta sessions))
            (error
             (kargu-log 'warn "failed to read session file %s: %s"
                        file (error-message-string err)))))))
    (sort sessions #'kargu-session-storage-newer-p)))

(provide 'kargu/chat/session/storage)
;;; storage.el ends here
