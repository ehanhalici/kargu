;;; webfetch.el --- Owned native public HTTP reads -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Native DNS, numeric policy, pinned HTTP, redirect and body budgets.
;; The editor supplies an owned callback; it never runs curl or a resolver.

;;; Code:

(require 'kargu/bridge/read)
(require 'kargu/api/tools)
(require 'kargu/permission/guards)

(defcustom kargu-webfetch-timeout 20
  "Total native webfetch deadline in seconds (positive, at most 30)."
  :type 'number :group 'kargu)
(defcustom kargu-webfetch-max-chars 50000
  "Maximum response body characters returned (0..131072)."
  :type 'natnum :group 'kargu)
(defcustom kargu-webfetch-resolve-timeout 5
  "Native DNS deadline in seconds (positive, at most 30)."
  :type 'number :group 'kargu)

(defun kargu-webfetch-url (callback url)
  "Fetch public URL through Rust into CALLBACK, returning a cancellable task."
  (let ((root (kargu-permission-project-root)))
    (kargu-bridge-read-task
     callback
     (kargu-bridge--object "url" url "timeout_ms" (ceiling (* 1000 kargu-webfetch-timeout))
                           "resolve_timeout_ms" (ceiling (* 1000 kargu-webfetch-resolve-timeout))
                           "max_chars" kargu-webfetch-max-chars)
     #'kargu-bridge-webfetch
     (lambda (result)
       (unless (equal root (kargu-permission-project-root)) (error "Webfetch owner project changed"))
       (gethash "text" result)))))

(defun kargu-webfetch-register-tools ()
  "Register the webfetch tool."
  (kargu-register-tool
   "webfetch"
   "Fetch a http/https URL and return the response body as text. Use for documentation pages the user named. Do not invent URLs."
   '(("type" . "object")
     ("properties" . (("url" . (("type" . "string")
                                ("description" . "Absolute http or https URL.")))))
     ("required" . ["url"]))
   (lambda (args &optional callback)
     (if (null callback)
         "ERROR: webfetch runs asynchronously; call it with a callback"
       (condition-case-unless-debug err
           (kargu-webfetch-url callback (kargu--tool-arg args "url"))
         (error (funcall callback (format "ERROR: %s" (error-message-string err)))))))))

(provide 'kargu/tools/webfetch)

;;; webfetch.el ends here
