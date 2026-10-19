;;; parameters.el --- Catalog-driven native request parameters -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Select one output cap and supported sampling fields without model-name
;; heuristics.  Metadata is interpreted by the catalog, defaults by providers.

;;; Code:

(require 'cl-lib)
(require 'kargu/api/catalog)
(require 'kargu/providers/catalog)

(defconst kargu-api-parameters--token-keys '("max_tokens" "max_completion_tokens")
  "Output-limit fields supported by the native chat-completions adapter.")

(defun kargu-api-parameters--token-key (policy parameters)
  "Select one output-limit field from POLICY and known model PARAMETERS."
  (let ((preferred (plist-get policy :max-output-key)))
    (unless (or (null preferred) (member preferred kargu-api-parameters--token-keys))
      (user-error "Kargu: provider request policy names an unsupported token-limit field"))
    (cond
     ((null parameters) preferred)
     ((member preferred parameters) preferred)
     (t (cl-find-if (lambda (key) (member key parameters)) kargu-api-parameters--token-keys)))))

(cl-defun kargu-api-request-parameters (&key model provider temperature max-tokens)
  "Return native request entries for MODEL at PROVIDER.
TEMPERATURE is included only when declared supported.  MAX-TOKENS uses one
accepted cap field; refuse an explicit cap that cannot be represented.
Unknown model parameters use the catalog's format/provider policy."
  (unless (or (null temperature) (numberp temperature))
    (user-error "Kargu: temperature must be a number or nil"))
  (unless (or (null max-tokens) (and (integerp max-tokens) (> max-tokens 0)))
    (user-error "Kargu: output token limit must be a positive integer or nil"))
  (let* ((policy (kargu-provider-request-policy provider))
         (parameters (kargu-model-request-parameters model provider))
         (token-key (kargu-api-parameters--token-key policy parameters))
         (sampling (if parameters parameters (plist-get policy :sampling-parameters))))
    (when (and max-tokens (null token-key))
      (user-error "Kargu: this model has no supported output-limit field; unset the cap or correct its metadata"))
    (append (and temperature (member "temperature" sampling)
                 `(("temperature" . ,temperature)))
            (and max-tokens (list (cons token-key max-tokens))))))

(provide 'kargu/api/parameters)
;;; parameters.el ends here
