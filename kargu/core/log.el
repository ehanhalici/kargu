;;; kargu/core/log.el --- Logging engine -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Kargu logging engine.
;; Public: `kargu-log', `kargu--log-block', `kargu--log-wire',
;; `kargu-toggle-wire-log', `kargu-show-log'.
;; Separated from `kargu/core' for single-responsibility.

;;; Code:

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

(require 'kargu/core/custom)

(defconst kargu--log-buffer "*kargu-log*"
  "Name of the kargu log buffer.")

(defun kargu--ensure-log-buffer ()
  "Return `*kargu-log*', creating it read-only with wrapping enabled."
  (let ((buf (get-buffer-create kargu--log-buffer)))
    (with-current-buffer buf
      (setq-local truncate-lines nil)
      (setq buffer-read-only t))
    buf))

(defun kargu-log (level format-string &rest args)
  "Append a log entry to the `*kargu-log*' buffer.
LEVEL is one of `debug', `info', `warn', `error', `request',
`response', `wire'.  FORMAT-STRING and ARGS are as in `format'.
The function never signals, so it is safe to call from curl
process filters and sentinels."
  (condition-case _err
      (with-current-buffer (kargu--ensure-log-buffer)
        (let ((inhibit-read-only t))
          (goto-char (point-max))
          (insert (format-time-string "%H:%M:%S ")
                  (propertize (format "[%s/%s] " level
                                      (if (boundp 'kargu-active-mode)
                                          kargu-active-mode
                                        'ask))
                              'face (pcase level
                                      ((or 'error 'warn) 'font-lock-warning-face)
                                      ('request 'font-lock-keyword-face)
                                      ('response 'font-lock-string-face)
                                      ('wire 'font-lock-type-face)
                                      (_ 'font-lock-comment-face)))
                  (apply #'format format-string args)
                  "\n")))
    (error nil)))

(defun kargu--log-limit (text)
  "Truncate TEXT to `kargu-log-dump-max' characters."
  (let ((s (if (stringp text) text (format "%s" (or text ""))))
        (max (if (boundp 'kargu-log-dump-max) kargu-log-dump-max 200000)))
    (if (and (natnump max) (> max 0) (> (length s) max))
        (concat (substring s 0 max)
                (format "\n...[truncated, %d more chars]"
                        (- (length s) max)))
      s)))

(defun kargu--log-looks-json-p (text)
  "Non-nil when TEXT looks like a JSON object or array."
  (and (stringp text)
       (let ((s (string-trim text)))
         (or (string-prefix-p "{" s) (string-prefix-p "[" s)))))

(declare-function json-pretty-print "json" (begin end &optional minimize))
(declare-function json-read "json" ())

(defun kargu--log-pretty (text)
  "Pretty-print TEXT when it is a single JSON value; otherwise TEXT."
  (if (not (kargu--log-looks-json-p text))
      text
    (condition-case nil
        (progn
          (require 'json)
          (with-temp-buffer
            (insert text)
            (goto-char (point-min))
            (json-read)
            (skip-chars-forward " \t\n\r")
            (unless (eobp)
              (error "trailing json"))
            (json-pretty-print (point-min) (point-max))
            (buffer-string)))
      (error text))))

(defun kargu--log-block (title text &optional pretty)
  "Append a titled dump of TEXT to the log when `kargu-log-wire' is on.
When PRETTY is non-nil, try to JSON-pretty-print TEXT first.
Never signals.  Does not log API keys."
  (when (and (boundp 'kargu-log-wire) kargu-log-wire)
    (condition-case _err
        (let* ((raw (if (stringp text) text (format "%s" (or text ""))))
               (body (kargu--log-limit (if pretty (kargu--log-pretty raw) raw))))
          (with-current-buffer (kargu--ensure-log-buffer)
            (let ((inhibit-read-only t))
              (goto-char (point-max))
              (insert (format-time-string "%H:%M:%S ")
                      (propertize (format "[wire/%s] "
                                          (if (boundp 'kargu-active-mode)
                                              kargu-active-mode
                                            'ask))
                                  'face 'font-lock-type-face)
                      (format "---- %s ----\n" title)
                      body
                      (if (string-suffix-p "\n" body) "" "\n")
                      (format "---- end %s ----\n" title)))))
      (error nil))))

(defun kargu--log-wire (format-string &rest args)
  "Like `kargu-log' at `wire', only when `kargu-log-wire' is on."
  (when (and (boundp 'kargu-log-wire) kargu-log-wire)
    (apply #'kargu-log 'wire format-string args)))

(defun kargu-toggle-wire-log ()
  "Toggle full request/response dumps in `*kargu-log*'."
  (interactive)
  (setq kargu-log-wire (not kargu-log-wire))
  (kargu-log 'info "wire log %s" (if kargu-log-wire "on" "off"))
  (kargu-show-log)
  (message "kargu wire log %s" (if kargu-log-wire "on" "off")))

(defun kargu-show-log ()
  "Pop to the kargu log buffer."
  (interactive)
  (pop-to-buffer (kargu--ensure-log-buffer)))

(provide 'kargu/core/log)

;;; kargu/core/log.el ends here
