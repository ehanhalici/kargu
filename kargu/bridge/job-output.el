;;; job-output.el --- Incremental native job output presentation -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Read bounded pages, retaining at most three incomplete UTF-8 bytes.
;; Rust owns the archive, process lifetime and terminal drain decision.

;;; Code:

(require 'kargu/bridge/jobs)

(cl-defstruct (kargu-bridge-output (:constructor kargu-bridge-output--create))
  "One non-overlapping output read loop and its editor continuations."
  job output finish timer (cursor 0) (carry "") closed)

(defun kargu-bridge-output--split (bytes eof)
  "Split unibyte BYTES into a complete UTF-8 prefix and carry, flushing at EOF."
  (let* ((size (length bytes)) (start (1- size)) (end size))
    (unless eof
      (while (and (>= start 0) (> start (- size 4))
                  (<= #x80 (aref bytes start)) (<= (aref bytes start) #xbf))
        (setq start (1- start)))
      (when (>= start 0)
        (let* ((lead (aref bytes start))
               (needed (cond ((<= #xc2 lead #xdf) 2)
                             ((<= #xe0 lead #xef) 3)
                             ((<= #xf0 lead #xf4) 4))))
          (when (and needed (< (- size start) needed)) (setq end start)))))
    (cons (decode-coding-string (substring bytes 0 end) 'utf-8)
          (substring bytes end))))

(defun kargu-bridge-output-close (reader)
  "Release READER's timer and callbacks, without cancelling its native job."
  (unless (kargu-bridge-output-closed reader)
    (setf (kargu-bridge-output-closed reader) t)
    (when (timerp (kargu-bridge-output-timer reader))
      (cancel-timer (kargu-bridge-output-timer reader)))
    (setf (kargu-bridge-output-timer reader) nil
          (kargu-bridge-output-output reader) nil
          (kargu-bridge-output-finish reader) nil)))

(defun kargu-bridge-output--finish (reader result error-data)
  "Finish READER once with actual terminal RESULT or ERROR-DATA."
  (unless (kargu-bridge-output-closed reader)
    (let ((callback (kargu-bridge-output-finish reader)))
      (kargu-bridge-output-close reader)
      (kargu-bridge--callback callback result error-data))))

(defun kargu-bridge-output--tick (reader)
  "Read one page for READER, then poll native terminal state."
  (unless (kargu-bridge-output-closed reader)
    (kargu-bridge-job-read
     (kargu-bridge-output-job reader) "stdout" (kargu-bridge-output-cursor reader)
     (lambda (page error-data)
       (unless (kargu-bridge-output-closed reader)
         (condition-case nil
             (if error-data (kargu-bridge-output--finish reader nil error-data)
               (let* ((start (gethash "start_cursor" page))
                      (next (gethash "next_cursor" page))
                      (gap (/= start (kargu-bridge-output-cursor reader)))
                      (eof (eq (gethash "eof" page) t))
                      (data (apply #'unibyte-string (append (gethash "data" page) nil)))
                      (decoded (kargu-bridge-output--split
                                (concat (unless gap (kargu-bridge-output-carry reader)) data) eof)))
                 (setf (kargu-bridge-output-cursor reader) next
                       (kargu-bridge-output-carry reader) (cdr decoded))
                 (funcall (kargu-bridge-output-output reader) (car decoded)
                          (or gap (eq (gethash "truncated" page) t)))
                 (kargu-bridge-output--status reader eof)))
           (error (kargu-bridge-output--finish reader nil (kargu-bridge--fault "output_failed")))))))))

(defun kargu-bridge-output--status (reader eof)
  "Poll READER's native completion after a page marked EOF or not."
  (kargu-bridge-job-status
   (kargu-bridge-output-job reader)
   (lambda (snapshot error-data)
     (unless (kargu-bridge-output-closed reader)
       (cond
        (error-data (kargu-bridge-output--finish reader nil error-data))
        ((and eof (hash-table-p snapshot) (equal (gethash "state" snapshot) "exited"))
         (kargu-bridge-output--finish reader (gethash "result" snapshot) nil))
        (t (setf (kargu-bridge-output-timer reader)
                 (run-at-time 0.05 nil #'kargu-bridge-output--tick reader))))))))

(defun kargu-bridge-output-start (job on-output on-finish)
  "Stream JOB's merged/stdout text to ON-OUTPUT (TEXT TRUNCATED).
ON-FINISH receives (RESULT ERROR) only after native terminal drain or failure.
This adapter never restarts a job or retains an unbounded output string."
  (let* ((reader (kargu-bridge-output--create :job job :output on-output :finish on-finish))
         (previous (kargu-bridge-job-on-close job)))
    (setf (kargu-bridge-job-on-close job)
          (lambda (result error-data)
            (when previous (funcall previous result error-data))
            (kargu-bridge-output--finish reader nil (or error-data (kargu-bridge--fault "job_closed")))))
    (kargu-bridge-output--tick reader)
    reader))

(provide 'kargu/bridge/job-output)
;;; job-output.el ends here
