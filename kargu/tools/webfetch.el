;;; webfetch.el --- Fetch a URL -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; `webfetch' tool: GET a URL via curl.  Requires: `kargu/core', `kargu/api'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'rx)
(require 'kargu/core)
(require 'kargu/contract)
(require 'kargu/api)
(require 'kargu/tools/process)
(require 'url-parse)
(require 'url-expand)

(defcustom kargu-webfetch-timeout 20
  "Seconds curl may spend on a webfetch request."
  :type 'natnum
  :group 'kargu)

(defcustom kargu-webfetch-max-chars 50000
  "Maximum characters returned from a webfetch response body.
Large bodies are truncated to prevent context window exhaustion."
  :type 'natnum
  :group 'kargu)

(defcustom kargu-webfetch-resolve-timeout 5
  "Seconds allowed for resolving one webfetch host."
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
        (and (string-search ":" h)
             (or (string-prefix-p "fe80:" h)
                 (string-prefix-p "fc" h)
                 (string-prefix-p "fd" h)))
        (kargu-webfetch--ipv4-private-p h))))

(defun kargu-webfetch--bare-host (parsed)
  "Hostname of PARSED, without brackets around an IPv6 literal."
  (let ((host (url-host parsed)))
    (and host (replace-regexp-in-string "\\`\\[\\|\\]\\'" "" host))))

(defun kargu-webfetch--port (parsed)
  "Port of PARSED, or the default for its scheme."
  (or (url-portspec parsed)
      (cdr (assoc (downcase (or (url-type parsed) ""))
                  '(("https" . 443) ("http" . 80))))
      80))

(defun kargu-webfetch--first-public (output)
  "First public address in getent ahosts OUTPUT.
The result is (public . IP), (private . IP), or (none . nil)."
  (let (seen private)
    (catch 'found
      (dolist (line (split-string (or output "") "\n" t))
        (when (string-match "\\`[ \t]*\\([^ \t]+\\)" line)
          (let ((ip (match-string 1 line)))
            (unless (member ip seen)
              (push ip seen)
              (if (kargu-webfetch--internal-host-p ip)
                  (unless private (setq private ip))
                (throw 'found (cons 'public ip)))))))
      (if private (cons 'private private) (cons 'none nil)))))

(defun kargu-webfetch--resolve (url callback)
  "Resolve URL and pass (IP ERR) to CALLBACK.
ERR is a reason string when no public address can be pinned.  The call
returns at once; `getent' runs through `kargu-process-run'."
  (let ((host (kargu-webfetch--bare-host (url-generic-parse-url url))))
    (kargu-process-run
     "getent" (list "ahosts" host)
     (lambda (result)
       (cond
        ((eql (plist-get result :code) 127)
         (funcall callback nil "webfetch cannot resolve the host: getent not found"))
        ((or (plist-get result :timed-out) (plist-get result :truncated)
             (not (eql (plist-get result :code) 0)))
         (funcall callback nil (format "webfetch could not resolve %s" host)))
        (t
         (let ((found (kargu-webfetch--first-public (plist-get result :output))))
           (pcase (car found)
             ('public (funcall callback (cdr found) nil))
             ('private
              (funcall callback nil
                       (format "webfetch refuses local or private address: %s"
                               (cdr found))))
             (_ (funcall callback nil
                         (format "webfetch could not resolve %s" host))))))))
     :timeout kargu-webfetch-resolve-timeout)))

(defun kargu-webfetch--resolve-mapping (host port ip)
  "Return a curl --resolve value pinning HOST:PORT to IP."
  (format "%s:%d:%s" host port
          (if (string-search ":" ip) (format "[%s]" ip) ip)))

(defun kargu-webfetch--curl-args (url ip)
  "Return curl arguments that GET URL from the resolved address IP."
  (let* ((parsed (url-generic-parse-url url))
         (host (kargu-webfetch--bare-host parsed)))
    (list "--disable" "-sS" "-i" "--noproxy" "*"
          "--max-time" (number-to-string kargu-webfetch-timeout)
          "-A" "kargu"
          "--proto" "=http,https"
          "--max-filesize" "5000000"
          "--resolve" (kargu-webfetch--resolve-mapping
                       host (kargu-webfetch--port parsed) ip)
          "--" url)))

(defun kargu-webfetch--check-url (url)
  "Signal an error unless URL is http(s) to a public host."
  (let* ((parsed (url-generic-parse-url url))
         (host (url-host parsed)))
    (unless (member (downcase (or (url-type parsed) "")) '("http" "https"))
      (error "Webfetch only fetches http or https URLs: %s" url))
    (when (or (null host) (string-empty-p host)
              (kargu-webfetch--internal-host-p host))
      (error "Webfetch refuses local or private address: %s" (or host url)))))

(defconst kargu-webfetch--max-redirects 5
  "Redirects followed before webfetch gives up.")

(defconst kargu-webfetch--header-separator
  (rx (opt "\r") "\n" (opt "\r") "\n")
  "Separator between one HTTP header block and its following bytes.")

(defun kargu-webfetch--parse-head (head)
  "Read status and redirect location from one HTTP header block HEAD."
  (let* ((case-fold-search t)
         (status (and (string-match
                       (rx string-start "HTTP/" (+ (any digit ".")) " "
                           (group (= 3 digit)) (or " " line-end)) head)
                      (string-to-number (match-string 1 head))))
         (location (and (string-match
                         (rx line-start "Location:" (* blank)
                             (group (+ (not (any "\r\n"))))) head)
                        (string-trim (match-string 1 head)))))
    (list :status status :location location)))

(defun kargu-webfetch--split-response (raw)
  "Split final curl -i response RAW into (:status :location :body).
Skip informational responses and preserve the caller's match data."
  (save-match-data
    (let ((offset 0))
      (catch 'final
        (while (string-match kargu-webfetch--header-separator raw offset)
          (let* ((head (substring raw offset (match-beginning 0)))
                 (body-start (match-end 0))
                 (reply (kargu-webfetch--parse-head head))
                 (status (plist-get reply :status)))
            (setq offset body-start)
            (unless (and status (<= 100 status 199))
              (throw 'final (plist-put reply :body (substring raw body-start))))))
        (error "Webfetch: incomplete HTTP response")))))

(defun kargu-webfetch--read-response (result url)
  "Parse curl RESULT from URL, or signal a transport failure."
  (cond
   ((plist-get result :timed-out) (error "Webfetch timed out: %s" url))
   ((plist-get result :truncated) (error "%s" (kargu-process-failure "Curl" result)))
   ((not (eql (plist-get result :code) 0))
    (error "Curl exit %s: %s" (plist-get result :code)
           (truncate-string-to-width (or (kargu-nonempty (plist-get result :stderr))
                                        (plist-get result :output) "") 200))))
  (kargu-webfetch--split-response (or (plist-get result :output) "")))

(defun kargu-webfetch--format-body (body)
  "BODY capped to `kargu-webfetch-max-chars', with a note when cut."
  (let ((text (kargu-cap-text body kargu-webfetch-max-chars "body")))
    (if (string-empty-p text) "(empty body)" text)))

(defun kargu-webfetch--handle (callback url left result)
  "Turn the curl RESULT for URL into a body, or follow a redirect.
LEFT redirects remain.  The final text, or an ERROR text, goes to CALLBACK."
  (condition-case-unless-debug err
      (let* ((reply (kargu-webfetch--read-response result url))
             (status (plist-get reply :status))
             (location (plist-get reply :location)))
        (cond
         ((null status) (error "Webfetch: invalid HTTP response"))
         ((and status (<= 300 status 399) location)
          (when (<= left 0) (error "Webfetch: too many redirects"))
          (let ((next (url-expand-file-name location url)))
            (kargu-webfetch--check-url next)
            (kargu-webfetch--fetch callback next (1- left))))
         ((<= 200 status 299)
          (funcall callback (kargu-webfetch--format-body (plist-get reply :body))))
         (t (error "Webfetch: HTTP %d from %s" status url))))
    (error (funcall callback (format "ERROR: %s" (error-message-string err))))))

(defun kargu-webfetch--fetch (callback url left)
  "GET URL with curl; pass the outcome to CALLBACK.  LEFT redirects remain.
The host is resolved first.  A private answer, or no resolver, becomes
ERROR text and curl is not started.  The first public address is pinned
with --resolve so curl does not look the name up again.  Each redirect
hop repeats this after `kargu-webfetch--check-url'."
  (kargu-webfetch--resolve
   url
   (lambda (ip err)
     (if err
         (funcall callback (format "ERROR: %s" err))
       (kargu-process-run
        "curl" (kargu-webfetch--curl-args url ip)
        (lambda (result) (kargu-webfetch--handle callback url left result))
        :timeout (+ kargu-webfetch-timeout 5)
        :max-bytes 6000000)))))

(defun kargu-webfetch-url (callback url)
  "GET URL and pass a truncated text body to CALLBACK."
  (kargu-contract-assert #'kargu-contract-url-p url
                         "Invalid webfetch URL (must be http or https): %S" url)
  (kargu-webfetch--check-url url)
  (unless (executable-find "curl")
    (error "Curl not found"))
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

;;; webfetch.el ends here
