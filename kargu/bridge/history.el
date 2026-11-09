;;; history.el --- Revision-bound native history display port -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Assemble bounded display pages supplied by Rust.  Message selection, content
;; parsing and protocol state remain native; the editor only consumes text DTOs.

;;; Code:

(require 'cl-lib)
(require 'kargu/async)
(require 'kargu/bridge/application)

(defconst kargu-bridge-history-display-bytes (* 4 1024 1024)
  "Maximum UTF-8 bytes retained for one native message's display projection.")

(cl-defun kargu-bridge-history-display
    (connection scope revision message-id callback &key parent owner valid-p)
  "Read MESSAGE-ID's display text at REVISION in native SCOPE on CONNECTION.
CALLBACK receives (TEXT FAILURE).  PARENT, OWNER and VALID-P bind UI lifetime.
No partial text is delivered after cancellation, malformed pages
or revision loss."
  (let* ((scope (kargu-bridge-application-copy-scope scope))
         (message-id (copy-sequence message-id))
         (epoch (copy-sequence (kargu-bridge-connection-epoch connection)))
         (origin (or owner (current-buffer)))
         (task (kargu-async-start
                callback :parent parent :owner nil :buffer origin :timeout 30
                :valid-p (lambda ()
                           (and (eq (kargu-bridge-status connection) 'ready)
                                (equal epoch (kargu-bridge-connection-epoch connection))
                                (or (null valid-p) (funcall valid-p))))))
         (sequence 0) active chunks
         (cancel (lambda () (kargu-async-cancel task))))
    (with-current-buffer origin
      (add-hook 'kill-buffer-hook cancel nil t)
      (add-hook 'change-major-mode-hook cancel nil t))
    (kargu-async-add-cleanup
     task (lambda ()
            (when active
              (let ((id active))
                (setq active nil)
                (when (equal epoch (kargu-bridge-connection-epoch connection))
                  (kargu-bridge-cancel connection id))))
            (when (buffer-live-p origin)
              (with-current-buffer origin
                (remove-hook 'kill-buffer-hook cancel t)
                (remove-hook 'change-major-mode-hook cancel t)))))
    (cl-labels
        ((receive (offset value failure)
           (let* ((text (and (hash-table-p value) (gethash "text" value)))
                  (next (and (hash-table-p value) (gethash "next_offset" value)))
                  (complete (and (hash-table-p value) (gethash "complete" value))))
             (cond
              (failure (kargu-async-finish task nil failure))
              ((not (and (hash-table-p value) (stringp text) (integerp next)
                         (equal revision (gethash "revision" value))
                         (equal message-id (gethash "message_id" value))
                         (equal "display" (gethash "projection" value))
                         (equal offset (gethash "offset" value))
                         (= next (+ offset (string-bytes text)))
                         (<= next kargu-bridge-history-display-bytes)
                         (memq complete '(t :json-false))
                         (or (eq complete t) (> next offset))))
               (kargu-async-finish task nil (kargu-bridge--fault "invalid_history_page")))
              (t
               (push text chunks)
               (if (eq complete t)
                   (kargu-async-finish task (apply #'concat (nreverse chunks)))
                 (page next))))))
         (page (offset)
           (let* ((generation (cl-incf sequence))
                  (id (kargu-bridge-call
                       connection "history/read"
                       (kargu-bridge--object
                        "scope" scope "arguments"
                        (kargu-bridge--object "revision" revision "message_id" message-id
                                             "offset" offset "projection" "display"))
                       (kargu-async-wrap
                        task (lambda (value failure)
                               (setq active nil)
                               (receive offset value failure)))
                       :owner origin
                       :timeout (max 0.001 (- (kargu-async-task-deadline task) (float-time))))))
             ;; An inline callback may issue another page or end the parent before
             ;; this call returns its ID. Do not replace that newer request's ID.
             (if (and (kargu-async-pending-p task) (= sequence generation))
                 (setq active id)
               (when (equal epoch (kargu-bridge-connection-epoch connection))
                 (kargu-bridge-cancel connection id))))))
      (funcall (kargu-async-wrap task (lambda () (page 0)))))
    task))

(provide 'kargu/bridge/history)
;;; history.el ends here
