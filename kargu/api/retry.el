;;; retry.el --- Captured native retry preferences and UI observers -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Rust alone owns replay classification, jitter, Retry-After and timers.
;; Elisp captures user preferences once and notifies the original UI consumer.

;;; Code:

(require 'kargu/core)
(require 'kargu/core/observers)
(require 'kargu/json)

(defvar kargu-api-retry-hook nil
  "Observers called with GENERATION and ON-DELTA before a native retry ACK.
ON-DELTA identifies the original consumer; no request secrets are exposed.")

(defun kargu-api-retry-preferences ()
  "Capture native retry preferences without locally deciding or clamping them."
  `(("retry_max" . ,kargu-api-retry-max)
    ("statuses" . ,(vconcat kargu-http-retry-statuses))
    ("retry_after_max_ms" . ,(* kargu-api-retry-after-max 1000))))

(defun kargu--log-out-payload (payload)
  "Wire-dump encoded PAYLOAD.  Never logs auth or API keys."
  (when kargu-log-wire
    (kargu--log-block "OUT request JSON" (kargu-json-encode-record payload) t)))

(provide 'kargu/api/retry)
;;; retry.el ends here
