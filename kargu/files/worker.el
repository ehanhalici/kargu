;;; worker.el --- Isolated bounded file-reading entrypoint -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Started explicitly in a batch Emacs.  No shell or Lisp input is evaluated.

;;; Code:

(require 'kargu/files)

(defun kargu-file-worker--dape-path (file-path root)
  "Return canonical FILE-PATH inside ROOT, or nil."
  (save-match-data
    (when (and (stringp file-path) (not (string-empty-p file-path))
               (not (file-remote-p file-path)))
      (condition-case nil
          (let ((path (file-truename (expand-file-name file-path root))))
            (when (kargu-permission-within-project-p path root) path))
        (file-error nil)))))

(defun kargu-file-worker--dape-disk-text (path budget)
  "Return bounded complete source text for canonical local PATH within BUDGET."
  (condition-case nil
      (when (and (file-regular-p path)
                 (<= (file-attribute-size (file-attributes path)) budget))
        (with-temp-buffer
          (set-buffer-multibyte nil)
          (let ((file-name-handler-alist nil)
                (format-alist nil)
                (after-insert-file-functions nil))
            (insert-file-contents-literally path nil 0 (1+ budget)))
          (when (<= (buffer-size) budget)
            (decode-coding-string (buffer-string)
                                  (detect-coding-region (point-min) (point-max) t)))))
    (file-error nil)))

(defun kargu-file-worker--read-dape (request)
  "Validate REQUEST and return canonical project path plus bounded source text."
  (kargu-contract-assert #'kargu-contract-non-empty-string-p (plist-get request :root))
  (kargu-contract-assert #'natnump (plist-get request :max-bytes))
  (let* ((file-name-coding-system 'utf-8-unix)
         (root (plist-get request :root))
         (budget (plist-get request :max-bytes))
         (kargu-permission--override-root root)
         (path (kargu-file-worker--dape-path (plist-get request :file) root))
         (text (and path (kargu-file-worker--dape-disk-text path budget))))
    (list :status "ok" :path path :text text)))

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
                   (let ((request (json-parse-string
                                   (decode-coding-string
                                    (base64-decode-string (pop command-line-args-left))
                                    'utf-8-unix)
                                   :object-type 'plist :null-object nil
                                   :false-object :json-false)))
                     (if (equal (plist-get request :mode) "dape-source")
                         (kargu-file-worker--read-dape request)
                       (list :status "ok" :text (kargu-file-worker--read request))))
                 (error (list :status "error" :text (error-message-string error))))))
    (let ((coding-system-for-write 'utf-8-unix))
      (princ (decode-coding-string
              (json-serialize reply :null-object nil :false-object :json-false)
              'utf-8-unix)))))

(provide 'kargu/files/worker)
;;; worker.el ends here
