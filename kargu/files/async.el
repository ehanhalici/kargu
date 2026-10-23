;;; async.el --- Owned nonblocking file excerpts -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Live buffers are sliced in place.  Target disk/path work stays in a bounded
;; helper process after the existing project-context resolver captures its root.

;;; Code:

(require 'kargu/files)
(require 'kargu/async)
(require 'kargu/tools/process)

(defconst kargu-file--worker-root
  (file-name-directory (directory-file-name
                        (file-name-directory (locate-library "kargu/files"))))
  "Package source root, independent of a native-compiled cache location.")

(defconst kargu-file--reply-overhead 8192
  "Character allowance for a reply's path, range header and truncation notice.")

(cl-defstruct (kargu-file-read-operation (:constructor kargu-file--make-read))
  "One immutable read request and its cancellable task."
  (path nil :read-only t) (window nil :read-only t) (origin nil :read-only t)
  (root nil :read-only t) (session nil :read-only t) (owner nil :read-only t)
  (max-bytes nil :read-only t) (scan-chars nil :read-only t)
  (output-chars nil :read-only t) (strict nil :read-only t) task)

(defun kargu-file--read-owner-valid-p (operation)
  "Return non-nil while OPERATION belongs to the same live conversation."
  (let ((origin (kargu-file-read-operation-origin operation)))
    (and (buffer-live-p origin)
         (eq (kargu-file-read-operation-owner operation) kargu--loop-run)
         (with-current-buffer origin
           (and (eq (kargu-file-read-operation-session operation) (kargu-session-context))
                (eq (kargu-file-read-operation-strict operation) kargu-permission-strict-mode)
                (equal (kargu-file-read-operation-root operation)
                       (kargu-permission-project-root)))))))

(defun kargu-file--live-excerpt (operation)
  "Read OPERATION's current live buffer, or return nil without a buffer."
  (let* ((path (kargu-file-read-operation-path operation))
         (output (kargu-tool-output-buffer path))
         (root (kargu-file-read-operation-root operation))
         (buffer (or output (get-file-buffer (expand-file-name path root)))))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (unless (or output (not (kargu-file-read-operation-strict operation))
                    (and buffer-file-truename (string-prefix-p root buffer-file-truename)))
          (error "Read_file live source is outside the permitted project"))
        (let ((kargu-diff-read-max-chars (kargu-file-read-operation-output-chars operation))
              (kargu-file-read-max-scan-chars (kargu-file-read-operation-scan-chars operation)))
          (save-restriction
            (widen)
            (kargu-file--describe-excerpt
             path (kargu-file--checked-excerpt (kargu-file-read-operation-window operation) t))))))))

(defun kargu-file--decode-read (operation process-result)
  "Validate PROCESS-RESULT against OPERATION before publishing its excerpt."
  (unless (and (eql 0 (plist-get process-result :code))
               (not (plist-get process-result :timed-out))
               (not (plist-get process-result :truncated)))
    (error "%s" (kargu-process-failure "File read" process-result)))
  (let* ((reply (json-parse-string (plist-get process-result :output) :object-type 'plist))
         (text (plist-get reply :text))
         (status (plist-get reply :status)))
    (kargu-contract-assert #'stringp text)
    (unless (<= (length text) (+ (kargu-file-read-operation-output-chars operation)
                                 kargu-file--reply-overhead))
      (error "File reader returned an oversized reply"))
    (pcase status
      ("ok" (or (kargu-file--live-excerpt operation) text))
      ("error" (error "%s" text))
      (_ (error "File reader returned an invalid status")))))

(defun kargu-file--worker-request (operation)
  "Encode OPERATION's captured fields as UTF-8 JSON bytes, not Lisp text."
  (let ((window (kargu-file-read-operation-window operation)))
    (json-serialize
     (list :file (kargu-file-read-operation-path operation)
           :root (kargu-file-read-operation-root operation)
           :from (kargu-file-window-from window) :to (kargu-file-window-to window)
           :strict (if (kargu-file-read-operation-strict operation) t :json-false)
           :max-bytes (kargu-file-read-operation-max-bytes operation)
           :scan-chars (kargu-file-read-operation-scan-chars operation)
           :output-chars (kargu-file-read-operation-output-chars operation))
     :null-object nil :false-object :json-false)))

(defun kargu-file--start-reader (operation)
  "Start OPERATION's helper unless a current live buffer supplies the excerpt."
  (let* ((task (kargu-file-read-operation-task operation))
         (live (kargu-file--live-excerpt operation)))
    (if live (kargu-async-finish task live)
      (let* ((args (list "--batch" "-Q" "-L" kargu-file--worker-root "-l" "kargu/files/worker"
                         "--eval" "(kargu-file-worker-main)" "--"
                         (base64-encode-string (kargu-file--worker-request operation) t)))
             (process (kargu-process-run
                       (expand-file-name invocation-name invocation-directory) args
                       (kargu-async-wrap task
                                         (lambda (result)
                                           (kargu-async-finish task (kargu-file--decode-read operation result))))
                       :dir temporary-file-directory
                       :max-bytes (* 8 (+ (kargu-file-read-operation-output-chars operation)
                                          kargu-file--reply-overhead)))))
        (when (processp process)
          (kargu-async-add-cleanup task (lambda () (kargu-process-cancel process))))))))

(defun kargu-file--attach-read-owner (operation)
  "Cancel OPERATION immediately if its origin buffer closes."
  (let* ((origin (kargu-file-read-operation-origin operation))
         (task (kargu-file-read-operation-task operation))
         (cancel (lambda () (kargu-async-cancel task))))
    (with-current-buffer origin (add-hook 'kill-buffer-hook cancel nil t))
    (kargu-async-add-cleanup
     task (lambda ()
            (when (buffer-live-p origin)
              (with-current-buffer origin (remove-hook 'kill-buffer-hook cancel t)))))))

(defun kargu-file-read-async (file-path window callback)
  "Read FILE-PATH's WINDOW asynchronously and report the excerpt to CALLBACK.
Return a cancellable task.  CALLBACK receives a bounded string or ERROR
description while its owner remains current; cancellation suppresses results.
Prefer current unsaved visiting buffers to delayed disk data."
  (kargu-contract-assert #'kargu-contract-filepath-p file-path)
  (kargu-contract-assert #'kargu-file-window-p window)
  (kargu-contract-assert #'functionp callback)
  (dolist (budget (list kargu-file-read-max-bytes kargu-file-read-max-scan-chars
                        kargu-diff-read-max-chars))
    (kargu-contract-assert #'natnump budget))
  (let* ((operation (kargu-file--make-read
                     :path (copy-sequence file-path) :window window :origin (current-buffer)
                     :root (kargu-permission-project-root) :session (kargu-session-context)
                     :owner kargu--loop-run :max-bytes kargu-file-read-max-bytes
                     :scan-chars kargu-file-read-max-scan-chars
                     :output-chars kargu-diff-read-max-chars :strict kargu-permission-strict-mode))
         (task (kargu-async-start
                (lambda (text error)
                  (when (kargu-file--read-owner-valid-p operation)
                    (funcall callback (if error (concat "ERROR: " error) text))))
                :valid-p (lambda () (kargu-file--read-owner-valid-p operation)))))
    (setf (kargu-file-read-operation-task operation) task)
    (kargu-file--attach-read-owner operation)
    (funcall (kargu-async-wrap task (lambda () (kargu-file--start-reader operation))))
    task))

(provide 'kargu/files/async)
;;; async.el ends here
