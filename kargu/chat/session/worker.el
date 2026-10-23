;;; worker.el --- Isolated bounded session metadata listing entrypoint -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Started explicitly in a batch Emacs.  No shell or Lisp input is evaluated.

;;; Code:

(require 'kargu/contract)
(require 'kargu/json)
(require 'kargu/chat/session/storage)

(defun kargu-session-worker--list (request)
  "Validate REQUEST and return bounded session metadata records."
  (dolist (key '(:root :sessions-directory :storage-location))
    (kargu-contract-assert #'kargu-contract-non-empty-string-p (plist-get request key)))
  (dolist (key '(:max-file-bytes :max-files :max-total-bytes))
    (kargu-contract-assert #'natnump (plist-get request key)))
  (let ((location (intern (plist-get request :storage-location))))
    (kargu-contract-assert (lambda (value) (memq value '(central project))) location)
    (let ((file-name-coding-system 'utf-8-unix)
          (kargu-sessions-directory (plist-get request :sessions-directory))
          (kargu-session-storage-location location)
          (kargu-session-max-file-bytes (plist-get request :max-file-bytes))
          (kargu-session-list-max-files (plist-get request :max-files))
          (kargu-session-list-max-total-bytes (plist-get request :max-total-bytes)))
      (vconcat (kargu-session-storage-list-metadata (plist-get request :root))))))

(defun kargu-session-worker-main ()
  "Read one base64 UTF-8 JSON request and print one bounded UTF-8 JSON reply."
  (when (equal (car command-line-args-left) "--") (pop command-line-args-left))
  (let ((reply (condition-case err
                   (let ((req (json-parse-string
                               (decode-coding-string
                                (base64-decode-string (pop command-line-args-left))
                                'utf-8-unix)
                               :object-type 'plist :null-object nil
                               :false-object :json-false)))
                     (list (cons "status" "ok")
                           (cons "sessions" (kargu-session-worker--list req))))
                 (error (list (cons "status" "error")
                              (cons "text" (error-message-string err)))))))
    (let ((coding-system-for-write 'utf-8-unix))
      (princ (kargu-json-encode-record reply)))))

(provide 'kargu/chat/session/worker)
;;; worker.el ends here
