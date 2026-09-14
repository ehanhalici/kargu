;;; kargu/loop/compact.el --- At most one compaction turn per run -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Tools-off summary turn.  Counts as one iteration.  Max one per run.

;;; Code:

(require 'cl-lib)
;; Ensure the package root is on `load-path' during byte/native
;; compilation from a subdirectory (Magit-style kargu/core features).
(eval-and-compile
  (let ((root (locate-dominating-file
               (or (bound-and-true-p byte-compile-current-file)
                   load-file-name
                   buffer-file-name
                   default-directory)
               "kargu.el")))
    (when root
      (add-to-list 'load-path (file-name-as-directory
                               (expand-file-name root))))))

(require 'kargu/core)
(require 'kargu/prompt)
(require 'kargu/history)
(require 'kargu/history-compact)
(require 'kargu/api)

(defvar kargu-max-iterations)
(defvar kargu--compaction-system)
(declare-function kargu-loop--live-p "kargu/loop" (run))
(declare-function kargu-loop--set-state "kargu/loop" (run state))
(declare-function kargu--loop-finish "kargu/loop" (run status &optional text))
(declare-function kargu--loop-request "kargu/loop/machine" (run prompt))

(defun kargu--loop-compact-allowed-p (run)
  "Non-nil when RUN may start at most one compaction turn."
  (and (not (plist-get run :compacting))
       (< (or (plist-get run :compactions) 0) 1)))

(defun kargu--loop-start-compact (run prompt)
  "Begin the single compaction turn for RUN, counting as one iteration.
Return non-nil if started."
  (when (and (kargu-loop--live-p run)
             (kargu--loop-compact-allowed-p run))
    (let ((iterations (1+ (or (plist-get run :iterations) 0))))
      (when (<= iterations kargu-max-iterations)
        (plist-put run :iterations iterations)
        (plist-put run :compactions 1)
        (plist-put run :resume-prompt prompt)
        (kargu--loop-begin-compaction run)
        t))))

(defun kargu--loop-begin-compaction (run)
  "Start a tools-off compaction turn for RUN, then resume."
  (when (kargu-loop--live-p run)
    (kargu-log 'info "loop: compacting history (%d chars)"
               (kargu-history-char-count))
    (kargu-loop--set-state run 'compact)
    (plist-put run :compacting t)
    (plist-put run :no-tools t)
    (plist-put run :compact-tail (kargu-history-compact-tail))
    (setq kargu--compaction-system kargu-prompt-compaction-system)
    (kargu-api-send
     kargu-prompt-compaction-user
     (lambda (response)
       (kargu--loop-handle-compaction run response)))))

(defconst kargu-loop--on-compaction
  '((error . kargu-loop--compaction-fail)
    (empty . kargu-loop--compaction-empty)
    (ok    . kargu-loop--compaction-apply))
  "Compaction response event -> handler.")

(defun kargu-loop--classify-compaction (response)
  "Event symbol for a compaction RESPONSE."
  (cond
   ((kargu-response-error-message response) 'error)
   ((null (kargu--nonempty (kargu-response-text response))) 'empty)
   (t 'ok)))

(defun kargu-loop--compaction-fail (run response)
  "Fail RUN after a compaction error in RESPONSE."
  (kargu--history-drop-trailing-compaction)
  (kargu--loop-finish run :error
                     (format "compaction failed: %s"
                             (kargu-response-error-message response))))

(defun kargu-loop--compaction-empty (run _response)
  "Fail RUN when compaction produced no summary."
  (kargu--history-drop-trailing-compaction)
  (kargu--loop-finish run :error "compaction produced an empty summary"))

(defun kargu-loop--compaction-apply (run response)
  "Apply the compaction summary in RESPONSE and resume RUN."
  (kargu-history-apply-compaction
   (kargu--nonempty (kargu-response-text response))
   (plist-get run :compact-tail))
  (plist-put run :just-compacted t)
  (plist-put run :compact-tail nil)
  (let ((resume (plist-get run :resume-prompt)))
    (plist-put run :resume-prompt nil)
    (when (and resume
               (not (string-empty-p resume))
               (equal (kargu--history-last-role) "user"))
      (kargu--history-add
       "assistant" "Acknowledged. Continuing from the summary."))
    (when (and (or (null resume) (string-empty-p resume))
               (kargu--history-completed-assistant-tail-p))
      (setq resume "Continue addressing the user's task based on the summary above."))
    (kargu--loop-request run resume)))

(defun kargu--loop-handle-compaction (run response)
  "Apply the compaction RESPONSE of RUN and continue the original work."
  (setq kargu--compaction-system nil)
  (when (kargu-loop--live-p run)
    (plist-put run :compacting nil)
    (plist-put run :no-tools nil)
    (funcall (alist-get (kargu-loop--classify-compaction response)
                        kargu-loop--on-compaction)
             run response)))

(provide 'kargu/loop/compact)

;;; kargu/loop/compact.el ends here
