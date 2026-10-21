;;; worker.el --- Isolated bounded file-reading entrypoint -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Started explicitly in a batch Emacs.  No shell or Lisp input is evaluated.

;;; Code:

(require 'kargu/files)

(defun kargu-file-worker--read (request)
  "Validate REQUEST and return a bounded permission-checked file excerpt."
  (dolist (key '(:file :root))
    (kargu-contract-assert #'kargu-contract-non-empty-string-p (plist-get request key)))
  (dolist (key '(:max-bytes :scan-chars :output-chars))
    (kargu-contract-assert #'natnump (plist-get request key)))
  (kargu-contract-assert (lambda (value) (memq value '(t :json-false)))
                         (plist-get request :strict))
  (let ((file-name-coding-system 'utf-8-unix)
        (kargu-permission--override-root (plist-get request :root))
        (kargu-permission-strict-mode (eq t (plist-get request :strict)))
        (kargu-file-read-max-bytes (plist-get request :max-bytes))
        (kargu-file-read-max-scan-chars (plist-get request :scan-chars))
        (kargu-diff-read-max-chars (plist-get request :output-chars)))
    (kargu-file-read-window
     (plist-get request :file)
     (kargu-file-window-create :from (plist-get request :from) :to (plist-get request :to)))))

(defun kargu-file-worker-main ()
  "Read one base64 UTF-8 JSON request and print one bounded UTF-8 JSON reply."
  (when (equal (car command-line-args-left) "--") (pop command-line-args-left))
  (let ((reply (condition-case error
                   (list :status "ok"
                         :text (kargu-file-worker--read
                                (json-parse-string (decode-coding-string
                                                    (base64-decode-string (pop command-line-args-left))
                                                    'utf-8-unix)
                                                   :object-type 'plist :null-object nil
                                                   :false-object :json-false)))
                 (error (list :status "error" :text (error-message-string error))))))
    (let ((coding-system-for-write 'utf-8-unix))
      (princ (decode-coding-string (json-serialize reply) 'utf-8-unix)))))

(provide 'kargu/files/worker)
;;; worker.el ends here
