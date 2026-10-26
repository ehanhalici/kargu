;;; async.el --- Owned native file excerpts and live editor snapshots -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Rust owns disk capture, decoding and excerpt presentation.  Emacs supplies
;; bounded live buffer text plus a modification tick; it never reads disk here.

;;; Code:

(require 'kargu/files)
(require 'kargu/async)
(require 'kargu/bridge/read)

(cl-defstruct (kargu-file-read-operation (:constructor kargu-file--make-read))
  "Captured editor authority for one native read."
  (path nil :read-only t) (window nil :read-only t) (origin nil :read-only t)
  (root nil :read-only t) (session nil :read-only t) (owner nil :read-only t)
  (max-bytes nil :read-only t) (scan-chars nil :read-only t)
  (output-chars nil :read-only t) (strict nil :read-only t) task)

(defun kargu-file--read-owner-valid-p (operation)
  "Whether OPERATION still belongs to the same conversation and root."
  (let ((origin (kargu-file-read-operation-origin operation)))
    (and (buffer-live-p origin)
         (eq (kargu-file-read-operation-owner operation) kargu--loop-run)
         (with-current-buffer origin
           (and (eq (kargu-file-read-operation-session operation) (kargu-session-context))
                (eq (kargu-file-read-operation-strict operation) kargu-permission-strict-mode)
                (equal (kargu-file-read-operation-root operation)
                       (kargu-permission-project-root)))))))

(defun kargu-file--live-source (operation)
  "Find OPERATION's live source without visiting or reading a file."
  (let* ((path (kargu-file-read-operation-path operation))
         (output (kargu-tool-output-buffer path))
         (root (kargu-file-read-operation-root operation))
         (buffer (or output (get-file-buffer (expand-file-name path root)))))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (unless (or output (not (kargu-file-read-operation-strict operation))
                    (and buffer-file-truename (string-prefix-p root buffer-file-truename)))
          (error "Read_file live source is outside the permitted project")))
      buffer)))

(defun kargu-file--capture-live (operation buffer)
  "Capture bounded raw text from BUFFER for OPERATION, preserving editor state.
Line motion is editor interop, not presentation: no numbering or EOF inference."
  (with-current-buffer buffer
    (save-excursion
      (save-restriction
        (widen)
        (let* ((end (point-max))
               (scan-end (min end (+ (point-min) (kargu-file-read-operation-scan-chars operation))))
               (probe (buffer-substring-no-properties (point-min) (min end (+ (point-min) 1000))))
               (from (kargu-file-window-from (kargu-file-read-operation-window operation))))
          (narrow-to-region (point-min) scan-end)
          (goto-char (point-min))
          (let* ((available (and (zerop (forward-line (1- from)))
                                 (or (= from 1) (< (point) (point-max)))))
                 (finish (min (point-max) (+ (point) (1+ (kargu-file-read-operation-output-chars operation))))))
            (kargu-bridge--object
             "kind" "editor" "probe" probe
             "from_available" (if available t :json-false)
             "complete" (if (= finish end) t :json-false)
             "text" (if available (buffer-substring-no-properties (point) finish) ""))))))))

(defun kargu-file--native-arguments (operation source)
  "Build OPERATION's immutable native request from raw SOURCE."
  (let ((window (kargu-file-read-operation-window operation)))
    (kargu-bridge--object
     "display_path" (kargu-file-read-operation-path operation)
     "window" (kargu-bridge--object "from" (kargu-file-window-from window)
                                    "to" (or (kargu-file-window-to window) :json-null))
     "max_bytes" (kargu-file-read-operation-max-bytes operation)
     "scan_chars" (kargu-file-read-operation-scan-chars operation)
     "output_chars" (kargu-file-read-operation-output-chars operation)
     "source" source)))

(defun kargu-file--start-reader (operation)
  "Start OPERATION through the native read port; never start an Elisp helper."
  (let* ((task (kargu-file-read-operation-task operation))
         (buffer (kargu-file--live-source operation))
         (tick (and buffer (with-current-buffer buffer (buffer-chars-modified-tick))))
         (path (kargu-file-read-operation-path operation))
         (source (if buffer (kargu-file--capture-live operation buffer)
                   (kargu-bridge--object
                    "kind" "disk" "root" (kargu-file-read-operation-root operation)
                    "path" path))))
    (let ((child (kargu-bridge-read-task
		  (kargu-async-wrap
		   task (lambda (text)
			  (let ((current (kargu-file--live-source operation)))
			    (cond
			     ((and (not buffer) current) (kargu-file--start-reader operation))
			     ((and buffer (or (not (eq buffer current))
					      (not (= tick (with-current-buffer buffer (buffer-chars-modified-tick))))))
			      (kargu-async-finish task nil "Live source changed while reading its snapshot"))
			     (t (kargu-async-finish task text))))))
		  (kargu-file--native-arguments operation source) #'kargu-bridge-read-file)))
      (kargu-async-add-cleanup
       child (lambda ()
               (unless (kargu-file--read-owner-valid-p operation)
                 (kargu-async-cancel task)))))))

(defun kargu-file--attach-read-owner (operation)
  "Cancel OPERATION immediately when its owner closes or changes major mode."
  (let* ((origin (kargu-file-read-operation-origin operation))
         (task (kargu-file-read-operation-task operation))
         (cancel (lambda () (kargu-async-cancel task))))
    (add-hook 'kill-buffer-hook cancel nil t)
    (add-hook 'change-major-mode-hook cancel nil t)
    (kargu-async-add-cleanup
     task (lambda ()
            (when (buffer-live-p origin)
              (with-current-buffer origin
                (remove-hook 'kill-buffer-hook cancel t)
                (remove-hook 'change-major-mode-hook cancel t)))))))

(defun kargu-file-read-async (file-path window callback)
  "Read FILE-PATH's WINDOW through Rust and deliver CALLBACK once.
Emacs supplies only live buffer text.  Cancellation and stale revisions discard
results; a newly opened live buffer supersedes an in-flight disk snapshot."
  (kargu-contract-assert #'kargu-contract-filepath-p file-path)
  (kargu-contract-assert #'kargu-file-window-p window)
  (kargu-contract-assert #'functionp callback)
  (when (file-remote-p file-path)
    (user-error "Kargu: remote read_file requires an asynchronous remote adapter"))
  (dolist (budget (list kargu-file-read-max-bytes kargu-file-read-max-scan-chars
                        kargu-diff-read-max-chars))
    (kargu-contract-assert #'natnump budget))
  (let* ((app (kargu-application-context))
         (operation (kargu-file--make-read
                     :path (copy-sequence file-path) :window window :origin (current-buffer)
                     :root (kargu-permission-project-root) :session (kargu-session-context)
                     :owner kargu--loop-run :max-bytes kargu-file-read-max-bytes
                     :scan-chars kargu-file-read-max-scan-chars
                     :output-chars kargu-diff-read-max-chars :strict kargu-permission-strict-mode))
         (task (kargu-async-start
                (kargu-application-wrap
                 app (lambda (text error)
                       (when (kargu-file--read-owner-valid-p operation)
                         (funcall callback (if error (concat "ERROR: " error) text)))))
                :valid-p (lambda () (kargu-file--read-owner-valid-p operation)))))
    (setf (kargu-file-read-operation-task operation) task)
    (kargu-file--attach-read-owner operation)
    (funcall (kargu-async-wrap task (lambda () (kargu-file--start-reader operation))))
    task))

(provide 'kargu/files/async)
;;; async.el ends here
