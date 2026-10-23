;;; worker.el --- Cancellable background credential worker -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Resolve explicitly configured local plaintext auth sources outside the UI
;; process.  The child has bounded time/output, never receives secrets in argv,
;; and emits a JSON result, not executable Lisp or raw exception messages.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'json)
(require 'rx)
(require 'kargu/contract/assert)
(require 'kargu/contract/result)
(require 'kargu/async)

(defvar auth-sources)

(defconst kargu-config-worker-max-bytes 65536
  "Maximum credential worker stdout bytes.")

(defconst kargu-config-worker-default-timeout 5.0
  "Default credential worker deadline in seconds.")

(defvar kargu-config-worker-runner-fn nil
  "Optional injected adapter (PROVIDER HOST TASK TIMEOUT).")

(defun kargu-config-worker-source-path (source)
  "Return SOURCE's local plaintext path, or nil without opening it."
  (let ((path (if (stringp source) source
                (and (consp source) (plist-get source :source))))
        (case-fold-search t))
    (when (and (stringp path)
               (not (file-remote-p path))
               (not (string-prefix-p "secrets:" path))
               (not (string-match-p (rx "." (or "gpg" "asc") eos) path)))
      (expand-file-name path))))

(defun kargu-config-worker-plain-sources ()
  "Return only explicitly configured local plaintext auth source paths."
  (and (boundp 'auth-sources) (listp auth-sources)
       (delq nil (mapcar #'kargu-config-worker-source-path auth-sources))))

(defun kargu-config-worker-unsupported-p ()
  "Return non-nil when configured auth sources have no supported local file."
  (and (boundp 'auth-sources) auth-sources
       (null (kargu-config-worker-plain-sources))))

(defun kargu-config-worker--script ()
  "Return the fixed credential worker entry expression."
  (prin1-to-string
   '(progn
      (require 'auth-source)
      (require 'json)
      (when (equal (car command-line-args-left) "--")
        (pop command-line-args-left))
      (let* ((host (pop command-line-args-left))
             (auth-sources (json-parse-string
                            (pop command-line-args-left) :array-type 'list))
             (auth-source-do-cache nil))
        (condition-case nil
            (let* ((found (and auth-sources (auth-source-search :host host :max 1)))
                   (secret (plist-get (car found) :secret)))
              (when (functionp secret) (setq secret (funcall secret)))
              (princ (json-serialize
                      (if (and (stringp secret) (> (length secret) 0))
                          (list :secret secret)
                        (list :error "unavailable")))))
          (error (princ "{\"error\":\"unavailable\"}")))))))

(defun kargu-config-worker--clean-buffer (buffer)
  "Erase and release private worker BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (widen)
        (erase-buffer)))
    (kill-buffer buffer)))

(defun kargu-config-worker--result (process buffer)
  "Decode PROCESS's bounded JSON from BUFFER without exposing error contents."
  (condition-case nil
      (let* ((data (and (= (process-exit-status process) 0)
                        (buffer-live-p buffer)
                        (with-current-buffer buffer
                          (json-parse-string (buffer-string) :object-type 'plist))))
             (secret (plist-get data :secret)))
        (if (and (stringp secret) (not (string-empty-p secret)))
            (kargu-ok secret)
          (kargu-err "Credential worker returned no usable credential" :auth-unavailable)))
    (error (kargu-err "Invalid credential worker response" :auth-unavailable))))

(defun kargu-config-worker--filter (task buffer)
  "Build a byte-bounded output filter for TASK and BUFFER."
  (let ((received 0))
    (lambda (_process chunk)
      (when (and (kargu-async-pending-p task) (buffer-live-p buffer))
        (cl-incf received (string-bytes chunk))
        (if (> received kargu-config-worker-max-bytes)
            (kargu-async-finish
             task (kargu-err "Credential worker output exceeded its bound" :auth-unavailable))
          (with-current-buffer buffer
            (goto-char (point-max))
            (insert chunk)))))))

(cl-defun kargu-config-worker-start (task script args &key decode (name "credential"))
  "Start TASK's bounded child running fixed SCRIPT with ARGS.
DECODE reads a finished child response; NAME identifies the operation."
  (let ((buffer (generate-new-buffer " *kargu-credential-worker*")) process)
    (with-current-buffer buffer (buffer-disable-undo))
    (kargu-async-add-cleanup
     task (lambda ()
            (when (and process (process-live-p process)) (delete-process process))
            (kargu-config-worker--clean-buffer buffer)))
    (when (kargu-async-pending-p task)
      (condition-case nil
          (progn
            (setq process
                  (make-process
                   :name (concat "kargu-" name "-worker") :buffer buffer
                   :command (append (list (expand-file-name invocation-name invocation-directory)
                                          "-Q" "--batch" "--eval" script "--") args)
                   :connection-type 'pipe :coding 'utf-8-unix :noquery t
                   :filter (kargu-config-worker--filter task buffer)
                   :sentinel (lambda (child _event)
                               (unless (process-live-p child)
                                 (kargu-async-finish
                                  task (funcall (or decode #'kargu-config-worker--result)
                                                child buffer))))))
            ;; A synchronous test adapter or early callback may have closed TASK.
            (unless (kargu-async-pending-p task)
              (when (process-live-p process) (delete-process process))))
        (error
         (kargu-async-finish
          task (kargu-err "Could not start configuration worker" :auth-unavailable)))))))

(defun kargu-config-worker--spawn (provider host sources task)
  "Start PROVIDER's worker for HOST and SOURCES, owned by TASK."
  (kargu-config-worker-start
   task (kargu-config-worker--script)
   (list host (json-serialize (vconcat sources))) :name provider))

(cl-defun kargu-config-worker-resolve (provider host task &key timeout)
  "Resolve PROVIDER's credential for HOST into TASK within TIMEOUT seconds.
Only explicit local plaintext sources are supported by the default worker."
  (kargu-contract-assert #'stringp provider)
  (kargu-contract-assert #'kargu-async-task-p task)
  (when (kargu-async-pending-p task)
    (let ((timer (run-at-time
                  (or timeout kargu-config-worker-default-timeout) nil
                  #'kargu-async-finish task
                  (kargu-err "Credential worker timed out" :auth-unavailable))))
      (kargu-async-add-cleanup task (lambda () (cancel-timer timer))))
    (cond
     ((functionp kargu-config-worker-runner-fn)
      (funcall kargu-config-worker-runner-fn provider host task timeout))
     ((not (and (stringp host) (not (string-empty-p host))))
      (kargu-async-finish task (kargu-err "Missing credential host" :auth-unavailable)))
     ((null (kargu-config-worker-plain-sources))
      (kargu-async-finish
       task (kargu-err "No supported local plaintext auth source" :auth-unavailable)))
     (t (kargu-config-worker--spawn
         provider host (kargu-config-worker-plain-sources) task)))))

(provide 'kargu/config/worker)
;;; worker.el ends here
