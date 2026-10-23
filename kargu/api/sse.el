;;; sse.el --- Incremental SSE transport decoding -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Decode complete UTF-8 event lines while preserving plz's raw response.
;; Enforces hard byte limits on raw buffer accumulation and incomplete SSE lines
;; to guarantee fail-fast abort on misbehaving streams (DEEP-12, MOD-04).

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'kargu/core)
(require 'kargu/json)
(require 'kargu/api/stream)

(defcustom kargu-stream-max-incomplete-line-bytes (* 64 1024)
  "Maximum allowable bytes in an incomplete SSE line buffer before a newline."
  :type 'natnum
  :group 'kargu)

(defcustom kargu-stream-max-raw-bytes (* 4 1024 1024)
  "Maximum allowable total raw bytes in a stream buffer."
  :type 'natnum
  :group 'kargu)

(defun kargu--api-note-stream-byte (process)
  "Record that PROCESS just received streaming output."
  (when (processp process)
    (process-put process :kargu-last-byte (float-time))))

(defun kargu-sse--abort (process reason)
  "Terminate PROCESS for REASON, retaining no partial parser payload."
  (unless (process-get process :kargu-stream-abort)
    (process-put process :kargu-stream-abort reason))
  (process-put process :kargu-raw nil)
  (process-put process :kargu-sse-parser nil)
  (when (process-live-p process) (delete-process process)))

(defun kargu-sse--feed-bytes (process string on-delta on-event)
  "Feed bounded STRING bytes from PROCESS to ON-DELTA and ON-EVENT."
  (let* ((raw (concat (or (process-get process :kargu-raw) "") string))
         (position (cl-position ?\n raw :from-end t))
         (tail (if position (substring raw (1+ position)) raw)))
    (when (> (string-bytes tail) kargu-stream-max-incomplete-line-bytes)
      (kargu-sse--abort process 'line-buffer-overflow)
      (error "SSE incomplete line exceeded its byte bound"))
    (process-put process :kargu-raw tail)
    (when position
      (let ((complete (decode-coding-string (substring raw 0 (1+ position)) 'utf-8)))
        (dolist (line (split-string (string-remove-suffix "\n" complete) "\n" nil))
          (kargu--stream-line process line on-delta on-event))))))

(defun kargu--stream-filter (process string on-delta &optional on-event)
  "Feed STRING from PROCESS to ON-DELTA and ON-EVENT under hard byte bounds.
Any protocol failure aborts this stream; partial data never becomes success."
  (save-match-data
    (unless (process-get process :kargu-stream-abort)
      (kargu--api-note-stream-byte process)
      (condition-case nil
          (let ((total (+ (or (process-get process :kargu-total-bytes) 0)
                          (string-bytes string)))
                (buffer (process-buffer process)))
            (when (> total kargu-stream-max-raw-bytes)
              (kargu-sse--abort process 'raw-buffer-overflow)
              (error "Stream raw byte bound exceeded"))
            (process-put process :kargu-total-bytes total)
            (when (buffer-live-p buffer)
              (with-current-buffer buffer
                (save-excursion
                  (save-restriction
                    (widen)
                    (goto-char (point-max))
                    (insert string)))))
            (kargu-sse--feed-bytes process string on-delta on-event))
        (error (kargu-sse--abort process 'protocol-failure))))))

(defun kargu--stream-flush (process on-delta on-event)
  "Flush PROCESS's last SSE line to ON-DELTA and ON-EVENT."
  (when (and (processp process) (not (process-get process :kargu-stream-abort)))
    (let ((rest (process-get process :kargu-raw)))
      (process-put process :kargu-raw nil)
      (when (and (stringp rest) (not (string-empty-p (string-trim rest))))
        (condition-case-unless-debug err
            (kargu--stream-line process (decode-coding-string rest 'utf-8)
                                on-delta on-event)
          (error (kargu-log 'error "stream flush error: %s"
                            (error-message-string err)))))
      (kargu--stream-line process "" on-delta on-event))))

(defun kargu--stream-line (process line on-delta &optional on-event)
  "Handle one complete SSE LINE from PROCESS.
Retain partial events until their blank-line delimiter.  Deliver completed
events to ON-EVENT and data events to ON-DELTA."
  (save-match-data
    (let ((parser (or (process-get process :kargu-sse-parser)
                      (let ((new (kargu-sse-parser-create)))
                        (process-put process :kargu-sse-parser new)
                        new))))
      (when-let* ((event (kargu-sse-parser-feed parser line)))
        (when (functionp on-event) (funcall on-event event))
        (when (and (not (eq event :done)) (functionp on-delta))
          (condition-case-unless-debug err
              (funcall on-delta event)
            (error
             (kargu-log 'warn "on-delta callback failed: %s"
                        (error-message-string err)))))))))

(provide 'kargu/api/sse)

;;; sse.el ends here
