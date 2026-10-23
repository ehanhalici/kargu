;;; cache.el --- Provider-independent prompt cache boundaries -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Mark stable system text, tools and completed history on a payload copy.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'kargu/json)

(defconst kargu-cache-runtime-boundary "<runtime_environment>\n"
  "Boundary between stable instructions and the changing environment suffix.")

(defconst kargu-cache--ephemeral '(("type" . "ephemeral"))
  "Default provider-managed prompt cache lifetime.")

(defun kargu-cache--text-block (text &optional marked)
  "Return a content block for TEXT with a cache boundary when MARKED."
  (append (list (cons "type" "text") (cons "text" text))
          (and marked (list (cons "cache_control" kargu-cache--ephemeral)))))

(defun kargu-cache--mark-entry (entry)
  "Add a cache marker in place to the private alist ENTRY."
  (if-let* ((marker (assoc "cache_control" entry)))
      (setcdr marker kargu-cache--ephemeral)
    (nconc entry (list (cons "cache_control" kargu-cache--ephemeral)))))

(defun kargu-cache--mark-message (message)
  "Mark the last nonempty text block of MESSAGE, returning non-nil on success."
  (let* ((content (kargu-aget message "content"))
         (blocks (if (stringp content)
                     (unless (string-empty-p content)
                       (list (kargu-cache--text-block content)))
                   (kargu-seq-to-list content)))
         (last-text (seq-find (lambda (block)
                                (and (equal (kargu-aget block "type") "text")
                                     (kargu-nonempty (kargu-aget block "text"))))
                              (reverse blocks))))
    (when last-text
      (kargu-cache--mark-entry last-text)
      (setcdr (assoc "content" message) (vconcat blocks))
      t)))

(defun kargu-cache--mark-system (message)
  "Mark MESSAGE's stable system prefix before the volatile environment."
  (let ((content (kargu-aget message "content")))
    (save-match-data
      (if-let* ((split (and (stringp content)
                            (string-match (regexp-quote kargu-cache-runtime-boundary) content)))
                ((> split 0)))
          (setcdr (assoc "content" message)
                  (vector (kargu-cache--text-block (substring content 0 split) t)
                          (kargu-cache--text-block (substring content split))))
        (kargu-cache--mark-message message)))))

(defun kargu-cache-prepare-messages (messages)
  "Put up to two cache boundaries on a private copy of MESSAGES.
Markers belong to content blocks, never message envelopes.  The latest
human turn is excluded; completed tool results can be cached immediately."
  (let* ((copy (copy-tree messages t))
         (system (car copy))
         (completed (if (equal (kargu-aget (car (last copy)) "role") "tool")
                        copy (butlast copy))))
    (when (equal (kargu-aget system "role") "system")
      (kargu-cache--mark-system system))
    (ignore (cl-some (lambda (message)
		       (and (not (equal (kargu-aget message "role") "system"))
			    (kargu-cache--mark-message message)))
		     (reverse completed)))
    copy))

(defun kargu-cache-prepare-tools (tools)
  "Mark the last canonical definition in a private copy of TOOLS."
  (let ((copy (copy-tree tools t)))
    (when (> (length copy) 0)
      (let ((tool (aref copy (1- (length copy)))))
        (kargu-cache--mark-entry tool)))
    copy))

(provide 'kargu/api/cache)
;;; cache.el ends here
