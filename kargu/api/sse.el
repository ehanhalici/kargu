;;; sse.el --- Incremental SSE transport decoding -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Decode complete UTF-8 event lines while preserving plz's raw response.

;;; Code:

(require 'kargu/core)
(require 'kargu/json)
(require 'kargu/api/stream)

(defun kargu--api-note-stream-byte (process)
  "Record that PROCESS just received streaming output."
  (when (processp process)
    (process-put process :kargu-last-byte (float-time))))

(defun kargu--stream-filter (process string on-delta &optional on-event)
  "Decode SSE bytes in STRING from PROCESS without blocking.
Preserve the raw process buffer for plz.  Deliver decoded events to
ON-DELTA and ON-EVENT while retaining incomplete UTF-8 lines."
  (save-match-data
    (kargu--api-note-stream-byte process)
    (condition-case-unless-debug err
        (let ((buffer (process-buffer process)))
          (when (buffer-live-p buffer)
            ;; (1) keep plz's view of the response intact
            (with-current-buffer buffer
              (save-excursion
                (save-restriction
                  (widen)
                  (goto-char (point-max))
                  (insert string))))
            ;; (2) side-channel SSE parsing on raw bytes
            (let* ((raw (concat (or (process-get process :kargu-raw)
                                    "")
                                string))
                   (pos (cl-position ?\n raw :from-end t)))
              (if (null pos)
                  (process-put process :kargu-raw raw)
                (let ((complete (decode-coding-string
                                 (substring raw 0 (1+ pos)) 'utf-8)))
                  (process-put process :kargu-raw (substring raw (1+ pos)))
                  (dolist (line (split-string complete "\n" t))
                    (kargu--stream-line process line on-delta on-event)))))))
      (error
       (kargu-log 'error "stream filter error: %s"
                  (error-message-string err))))))

(defun kargu--stream-flush (process on-delta on-event)
  "Flush PROCESS's last SSE line to ON-DELTA and ON-EVENT."
  (when (processp process)
    (let ((rest (process-get process :kargu-raw)))
      (process-put process :kargu-raw nil)
      (when (and (stringp rest) (not (string-empty-p (string-trim rest))))
        (condition-case-unless-debug err
            (kargu--stream-line process (decode-coding-string rest 'utf-8)
                                on-delta on-event)
          (error (kargu-log 'error "stream flush error: %s"
                            (error-message-string err))))))))

(defun kargu--stream-line (process line on-delta &optional on-event)
  "Handle one complete SSE LINE from PROCESS.
Non-\"data:\" lines (HTTP headers, comments, keep-alives) are
ignored.  PROCESS is only used for logging context."
  (save-match-data
    (ignore process)
    (setq line (string-trim-right line "\r"))
    (when (string-prefix-p "data:" line)
      (let ((data (string-trim (substring line (length "data:")))))
        (cond
         ((equal data "[DONE]")
          (when (functionp on-event) (funcall on-event :done)))
         ((not (string-empty-p data))
          (kargu--log-block "SSE data" data t)
          (when-let* ((event (kargu-sse-decode-data data)))
            (when (functionp on-event)
              (funcall on-event event))
            (when (functionp on-delta)
              (condition-case-unless-debug err
                  (funcall on-delta event)
                (error
                 (kargu-log 'warn "on-delta callback failed: %s"
                            (error-message-string err))))))))))))

(provide 'kargu/api/sse)

;;; sse.el ends here
