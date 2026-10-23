;;; schema.el --- Pure session schema migration -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Version two preserves inherited effort, explicit off and API values.
;; Reading a legacy record never rewrites its file or consults credentials.

;;; Code:

(require 'kargu/contract/selection)
(require 'subr-x)

(defconst kargu-session-schema-version 2
  "Current persisted session schema version.")

(defun kargu-session-encode-effort (effort)
  "Return a JSON record preserving the exact EFFORT choice."
  (cond
   ((eq effort kargu-selection-default-effort) '(("kind" . "inherit")))
   ((null effort) '(("kind" . "off")))
   ((symbolp effort) `(("kind" . "value") ("value" . ,(symbol-name effort))))
   (t (error "Invalid session effort"))))

(defun kargu-session-decode-effort (record)
  "Return the canonical effort encoded by the validated JSON RECORD."
  (unless (hash-table-p record) (user-error "Kargu: invalid session effort record"))
  (let ((kind (gethash "kind" record)) (value (gethash "value" record)))
    (cond
     ((and (equal kind "inherit") (null value)) kargu-selection-default-effort)
     ((and (equal kind "off") (null value)) nil)
     ((and (equal kind "value") (stringp value) (not (string-empty-p value))
           (not (equal value "nil")))
      (intern value))
     (t (user-error "Kargu: invalid session effort choice")))))

(defun kargu-session-migrate (record)
  "Return a migrated copy of typed JSON RECORD, rejecting unknown versions."
  (unless (hash-table-p record) (user-error "Kargu: expected a session object"))
  (let ((version (gethash "schema_version" record :legacy))
        (copy (copy-hash-table record)))
    (cond
     ((eq version :legacy)
      (puthash "schema_version" kargu-session-schema-version copy)
      (let ((effort (make-hash-table :test #'equal)))
        (puthash "kind" "inherit" effort)
        (puthash "effort" effort copy)))
     ((not (eql version kargu-session-schema-version))
      (user-error "Kargu: unsupported session schema version")))
    (kargu-session-decode-effort (gethash "effort" copy))
    copy))

(provide 'kargu/chat/session/schema)
;;; schema.el ends here
