;;; tool-calls.el --- Canonical tool-call identities -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Assign identities once before history and execution consume a response.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'kargu/core)
(require 'kargu/contract/result)
(require 'kargu/history/store)
(require 'kargu/json)


(defun kargu-api--used-tool-call-ids (&optional history)
  "Return a set of tool-call identities already present in HISTORY."
  (let ((used (make-hash-table :test #'equal)))
    (dolist (message (kargu-history-messages history))
      (when-let* ((result-id (kargu-aget message "tool_call_id")))
        (puthash result-id t used))
      (dolist (call (kargu-seq-to-list (kargu-aget message "tool_calls")))
        (when-let* ((id (kargu-aget call "id"))) (puthash id t used))))
    used))

(defun kargu-api--fresh-tool-call-id (used)
  "Generate an identity not already in USED."
  (let ((prefix (substring (secure-hash 'sha1 (kargu-session-id)) 0 12))
        (sequence (hash-table-count used)) id)
    (while (or (null id) (gethash id used))
      (setq id (format "call_kargu_%s_%d" prefix (cl-incf sequence))))
    id))

(defun kargu-api--normalize-tool-call (call used)
  "Give CALL one nonempty identity not already in USED, then reserve it."
  (unless (kargu--object-p call) (error "Malformed tool call"))
  (let ((id (kargu-aget call "id")))
    (unless (and (stringp id) (not (string-empty-p (string-trim id)))
                 (not (gethash id used)))
      (setq id (kargu-api--fresh-tool-call-id used)))
    (setf (alist-get "id" call nil nil #'equal) id)
    (puthash id t used)
    call))

(defun kargu-api--normalize-message-calls (message used)
  "Normalize tool identities in MESSAGE using USED, including legacy data."
  (let* ((raw (kargu-aget message "tool_calls"))
         (legacy (and (memq raw '(nil :json-null))
                      (kargu-aget message "function_call")))
         (calls (if (kargu--object-p legacy)
                    (list (list (cons "type" "function") (cons "function" legacy)))
                  (unless (eq raw :json-null) (kargu-seq-to-list raw)))))
    (when calls
      (setf (alist-get "tool_calls" message nil nil #'equal)
            (vconcat (mapcar (lambda (call) (kargu-api--normalize-tool-call call used)) calls)))
      (when legacy (setq message (assoc-delete-all "function_call" message))))
    message))

(defun kargu-api-normalize-tool-calls (response &optional history)
  "Return a canonical copy of RESPONSE with unique tool-call identities.
Preserve valid provider IDs unless they collide within this response or
with HISTORY or the current owner.  Every consumer uses this same response."
  (if (kargu-err-p response)
      response
    (condition-case err
        (let ((copy (kargu-json-to-record response)) (used (kargu-api--used-tool-call-ids history)))
          (dolist (choice (kargu-seq-to-list (kargu-aget copy "choices")))
            (when-let* ((message (kargu-aget choice "message")))
              (setcdr (assoc "message" choice) (kargu-api--normalize-message-calls message used))))
          copy)
      (error `(("error" . (("message" . ,(format "Invalid tool calls: %s" (error-message-string err))))))))))

(provide 'kargu/api/tool-calls)
;;; tool-calls.el ends here
