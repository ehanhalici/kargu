;;; kargu/tools/webfetch.el --- Fetch a URL -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; `webfetch' tool: GET a URL via curl.  Requires: `kargu/core', `kargu/api'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'kargu/core)
(require 'kargu/contract)
(require 'kargu/api)
(require 'kargu/tools/process)
(require 'url-parse)

(defcustom kargu-webfetch-timeout 20
  "Seconds curl may spend on a webfetch request."
  :type 'natnum
  :group 'kargu)

(defcustom kargu-webfetch-max-chars 50000
  "Maximum characters returned from a webfetch response body.
Large bodies are truncated to prevent context window exhaustion."
  :type 'natnum
  :group 'kargu)

(defun kargu-webfetch--ipv4-private-p (host)
  "Non-nil when HOST is an IPv4 literal in a loopback, private or link-local range."
  (when (string-match "\\`\\([0-9]+\\)\\.\\([0-9]+\\)\\.\\([0-9]+\\)\\.\\([0-9]+\\)\\'" host)
    (let ((a (string-to-number (match-string 1 host)))
          (b (string-to-number (match-string 2 host))))
      (or (memq a '(0 10 127))
          (and (= a 169) (= b 254))
          (and (= a 172) (<= 16 b 31))
          (and (= a 192) (= b 168))
          (and (= a 100) (<= 64 b 127))
          (>= a 224)))))

(defun kargu-webfetch--internal-host-p (host)
  "Non-nil when HOST names this machine or a private network."
  (let ((h (downcase (string-trim host "[[]" "[]]"))))
    (or (member h '("localhost" "0.0.0.0" "::" "::1"))
        (string-suffix-p ".localhost" h)
        (string-suffix-p ".local" h)
        (string-suffix-p ".internal" h)
        (string-prefix-p "fe80:" h)
        (string-prefix-p "fc" h)
        (string-prefix-p "fd" h)
        (kargu-webfetch--ipv4-private-p h))))

(defun kargu-webfetch--check-url (url)
  "Signal an error unless URL is http(s) to a public host."
  (let* ((parsed (url-generic-parse-url url))
         (host (url-host parsed)))
    (unless (member (downcase (or (url-type parsed) "")) '("http" "https"))
      (error "webfetch only fetches http or https URLs: %s" url))
    (when (or (null host) (string-empty-p host)
              (kargu-webfetch--internal-host-p host))
      (error "webfetch refuses local or private address: %s" (or host url)))))

(defconst kargu-webfetch--max-redirects 5
  "Redirects followed before webfetch gives up.")

(defun kargu-webfetch--split-response (raw)
  "Split a curl -i answer RAW into a plist (:status :location :body)."
  (let* ((sep (string-match "\r?\n\r?\n" raw))
         (head (if sep (substring raw 0 sep) raw))
         (body (if sep (substring raw (match-end 0)) ""))
         (status (and (string-match "\\`HTTP/[0-9.]+ \\([0-9]+\\)" head)
                      (string-to-number (match-string 1 head))))
         (location (and (string-match "^[Ll]ocation:[ \t]*\\([^\r\n]+\\)" head)
                        (string-trim (match-string 1 head)))))
    (list :status status :location location :body body)))

(defun kargu-webfetch--format-body (body)
  "BODY capped to `kargu-webfetch-max-chars', with a note when cut."
  (let ((text (kargu-cap-text body kargu-webfetch-max-chars "body")))
    (if (string-empty-p text) "(empty body)" text)))

(defun kargu-webfetch--handle (callback url left result)
  "Turn the curl RESULT for URL into a body, or follow a redirect.
LEFT redirects remain.  The final text, or an ERROR text, goes to CALLBACK."
  (condition-case-unless-debug err
      (let* ((code (plist-get result :code))
             (reply (kargu-webfetch--split-response (or (plist-get result :output) "")))
             (status (plist-get reply :status))
             (location (plist-get reply :location)))
        (cond
         ((plist-get result :timed-out) (error "webfetch timed out: %s" url))
         ((not (eql code 0))
          (error "curl exit %s: %s" code
                 (truncate-string-to-width (or (plist-get result :output) "") 200)))
         ((and status (<= 300 status 399) location)
          (when (<= left 0) (error "webfetch: too many redirects"))
          (let ((next (url-expand-file-name location url)))
            (kargu-webfetch--check-url next)
            (kargu-webfetch--fetch callback next (1- left))))
         (t (funcall callback (kargu-webfetch--format-body (plist-get reply :body))))))
    (error (funcall callback (format "ERROR: %s" (error-message-string err))))))

(defun kargu-webfetch--fetch (callback url left)
  "GET URL with curl; pass the outcome to CALLBACK.  LEFT redirects remain.
curl never follows redirects itself: each hop is checked by
`kargu-webfetch--check-url' before it is requested."
  (kargu-process-run
   "curl"
   (list "-sS" "-i"
         "--max-time" (number-to-string kargu-webfetch-timeout)
         "-A" "kargu"
         "--proto" "=http,https"
         "--max-filesize" "5000000"
         "--" url)
   (lambda (result) (kargu-webfetch--handle callback url left result))
   :timeout (+ kargu-webfetch-timeout 5)
   :max-bytes 6000000))

(defun kargu-webfetch-url (callback url)
  "GET URL and pass a truncated text body to CALLBACK."
  (kargu-contract-assert #'kargu-contract-url-p url
                         "Invalid webfetch URL (must be http or https): %S" url)
  (kargu-webfetch--check-url url)
  (unless (executable-find "curl")
    (error "curl not found"))
  (kargu-webfetch--fetch callback url kargu-webfetch--max-redirects))

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

(kargu-webfetch-register-tools)

(provide 'kargu/tools/webfetch)

;;; kargu/tools/webfetch.el ends here
