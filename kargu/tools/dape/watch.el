;;; watch.el --- Connection-owned debugger watch expressions -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Kargu watches belong to one adapter, workspace and chat session.  Dape's
;; global UI watch collection is deliberately neither imported nor modified.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'kargu/core/session)
(require 'kargu/permission)

(declare-function kargu-session-id "kargu/core/session" ())

(defvar kargu-dape--watches (make-hash-table :test #'eq :weakness 'key)
  "Adapter-keyed watch collections; a discarded adapter does not stay alive.")

(cl-defstruct (kargu-dape--watches (:constructor kargu-dape--make-watches))
  "One workspace/session's expressions for an adapter."
  root session expressions)

(defun kargu-dape-watch-expressions (connection &optional expression remove-p)
  "Return copied watch expressions for CONNECTION in the current session.
EXPRESSION adds one watch, or removes it when REMOVE-P is non-nil.
Empty expressions only read the collection.  New watches appear first;
Dape's global watch list and UI are not consulted or changed."
  (unless connection (user-error "Watch expressions require a debug connection"))
  (unless (or (null expression) (stringp expression))
    (user-error "Watch expression must be a string"))
  (let* ((root (kargu-permission-project-root))
         (session (kargu-session-id))
         (entries (gethash connection kargu-dape--watches))
         (collection (seq-find
                      (lambda (entry)
                        (and (equal root (kargu-dape--watches-root entry))
                             (equal session (kargu-dape--watches-session entry))))
                      entries)))
    (when (and expression (not (string-empty-p (string-trim expression))))
      (unless collection
        (setq collection (kargu-dape--make-watches
                          :root (copy-sequence root) :session (copy-sequence session)))
        (puthash connection (cons collection entries) kargu-dape--watches))
      (let ((expressions (kargu-dape--watches-expressions collection)))
        (setf (kargu-dape--watches-expressions collection)
              (cond
               (remove-p (delete expression expressions))
               ((member expression expressions) expressions)
               (t (cons (copy-sequence expression) expressions))))))
    (when collection
      (mapcar #'copy-sequence (kargu-dape--watches-expressions collection)))))

(provide 'kargu/tools/dape/watch)
;;; watch.el ends here
