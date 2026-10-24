;;; wire.el --- Editor access to captured native wire metadata -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Format transformation and cache boundaries are owned by Rust.  This module
;; retains metadata access and the temporary history identity adapter only.

;;; Code:

(require 'subr-x)
(require 'kargu/providers/catalog)
(require 'kargu/api/tool-calls)
(require 'kargu/config/connection)

(declare-function kargu-provider-format "kargu/providers/registry" (id))
(declare-function kargu-provider-format-record "kargu/providers/registry" (format))
(declare-function kargu--provider-name "kargu/config/key" ())

(defun kargu-api-wire-record (format)
  "Return FORMAT's captured wire record inside a connection boundary."
  (if (kargu-connection-current)
      (kargu-connection-setting :wire)
    (kargu-provider-format-record format)))

(defun kargu-api-active-format ()
  "Catalog format symbol of the active provider, or nil."
  (if (kargu-connection-current)
      (kargu-connection-setting :format)
    (when (fboundp 'kargu-provider-format)
    (let ((pname (if (fboundp 'kargu--provider-name) (kargu--provider-name) "")))
      (kargu-provider-format
       (downcase (string-trim (format "%s" (or pname "")))))))))

(defun kargu-api-chat-url (base format)
  "Chat endpoint for BASE and catalog FORMAT.
The path comes from the format record.  A missing record uses
`/chat/completions'."
  (let ((path (or (plist-get (kargu-api-wire-record format) :chat-path)
                  "/chat/completions")))
    (concat base path)))

(defun kargu-api-normalize-response (response)
  "Normalize canonical RESPONSE's identities for the current history store.
Provider-specific wire normalization has already completed inside Rust."
  (kargu-api-normalize-tool-calls response))

(provide 'kargu/api/wire)
;;; wire.el ends here
