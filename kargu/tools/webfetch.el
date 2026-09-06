;;; kargu/tools/webfetch.el --- Fetch a URL -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; `webfetch' tool: GET a URL via curl.  Requires: `kargu/core', `kargu/api'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
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
(require 'kargu/contract)
(require 'kargu/api)

(defcustom kargu-webfetch-timeout 20
  "Seconds curl may spend on a webfetch request."
  :type 'natnum
  :group 'kargu)

(defcustom kargu-webfetch-max-chars 50000
  "Maximum characters returned from a webfetch response body.
Large bodies are truncated to prevent context window exhaustion."
  :type 'natnum
  :group 'kargu)

(defun kargu-webfetch-url (url)
  "GET URL and return a truncated text body."
  (kargu-contract-assert #'kargu-contract-url-p url
                         "Invalid webfetch URL (must be http or https): %S" url)
  (unless (executable-find "curl")
    (error "curl not found"))
  (with-temp-buffer
    (let ((code (with-local-quit
                  (call-process "curl" nil t nil
                                "-sS" "-L"
                                "--max-time" (number-to-string kargu-webfetch-timeout)
                                "-A" "kargu"
                                "--max-redirs" "5"
                                "--"
                                url))))
      (when (null code)
        (error "webfetch interrupted by user (C-g)"))
      (unless (eq code 0)
        (error "curl exit %s: %s" code
               (truncate-string-to-width (buffer-string) 200)))
      (let* ((body (buffer-string))
             (len (length body))
             (truncated (> len kargu-webfetch-max-chars))
             (text (if truncated
                       (concat (substring body 0 kargu-webfetch-max-chars)
                               (format "\n... [truncated; body was %d chars, capped at %d]"
                                       len kargu-webfetch-max-chars))
                     body)))
        (if (string-empty-p text)
            "(empty body)"
          text)))))

(defun kargu-webfetch-register-tools ()
  "Register the webfetch tool."
  (kargu-register-tool
   "webfetch"
   "Fetch a http/https URL and return the response body as text. Use for documentation pages the user named. Do not invent URLs."
   '(("type" . "object")
     ("properties" . (("url" . (("type" . "string")
                                ("description" . "Absolute http or https URL.")))))
     ("required" . ["url"]))
   (lambda (args)
     (condition-case-unless-debug err
         (kargu-webfetch-url (kargu--tool-arg args "url"))
       (error (format "ERROR: %s" (error-message-string err)))))))

(kargu-webfetch-register-tools)

(provide 'kargu/tools/webfetch)

;;; kargu/tools/webfetch.el ends here
