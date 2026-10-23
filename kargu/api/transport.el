;;; transport.el --- Non-redirecting authenticated HTTP boundary -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Never replay a captured credential or request body at a redirected target.
;; Bind curl policy per request, without altering other plz consumers.

;;; Code:

(require 'plz)

(defconst kargu-transport--curl-policy
  '("--location" "--max-redirs" "0" "--no-insecure"
    "--proto" "=http,https" "--proto-redir" "=http,https")
  "Final curl switches enforcing endpoint and TLS authority.")

(defun kargu-transport--deliver (response then otherwise)
  "Deliver RESPONSE to THEN, or report redirects through OTHERWISE."
  (if (and (plz-response-p response)
           (<= 300 (plz-response-status response))
           (< (plz-response-status response) 400))
      (let ((safe (copy-plz-response response)))
        (setf (plz-response-body safe) "")
        (funcall otherwise
                 (make-plz-error :response safe
                                 :message "Redirect refused; configure the final API endpoint")))
    (funcall then (if (plz-response-p response) (plz-response-body response) response))))

(defun kargu-transport-request (method url &rest options)
  "Send METHOD to URL with asynchronous OPTIONS, refusing all redirects."
  (let* ((plz-curl-default-args (append plz-curl-default-args kargu-transport--curl-policy))
         (then (plist-get options :then))
         (otherwise (plist-get options :else)))
    ;; Zero redirects makes curl exit 47 before following Location.  This also
    ;; avoids plz 0.9's unconditional skipping of final 3xx response headers.
    (setq options (plist-put options :else
                             (lambda (error)
                               (funcall otherwise
                                        (if (and (plz-error-p error)
                                                 (equal (car-safe (plz-error-curl-error error)) 47))
                                            (make-plz-error :message "Redirect refused; configure the final API endpoint")
                                          error)))))
    (setq options (plist-put options :as 'response))
    (setq options (plist-put options :then
                             (lambda (response)
                               (kargu-transport--deliver response then otherwise))))
    (apply #'plz method url options)))

(provide 'kargu/api/transport)
;;; transport.el ends here
