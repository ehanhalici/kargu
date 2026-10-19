;;; store.el --- Provider-owned model metadata storage -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; This module alone owns metadata records and explicit property overrides.
;; Providers are normalized; opaque model IDs retain their case.  A short
;; alias resolves only within one provider and only when it is unambiguous.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'kargu/json)

(cl-defstruct (kargu-model-entry (:constructor kargu-model-store--entry))
  "One provider's canonical model data and persistent local overrides."
  provider id data overrides)

(defvar kargu--model-metadata-table (make-hash-table :test #'equal)
  "Owned metadata entries keyed by (PROVIDER . MODEL-ID).
Only this module writes the table.  Updates replace entries, never mutate
records retained by snapshots or another reader.")

(defun kargu-model-store--provider (provider)
  "Return the canonical identity of explicit PROVIDER."
  (unless (and provider (or (stringp provider) (symbolp provider)))
    (user-error "Kargu: model metadata requires a provider"))
  (let ((provider (downcase (string-trim (format "%s" provider)))))
    (when (string-empty-p provider)
      (user-error "Kargu: model metadata requires a nonempty provider"))
    provider))

(defun kargu-model-store--key (provider id)
  "Return the storage identity for explicit PROVIDER and model ID."
  (unless (and (stringp id) (not (string-empty-p (string-trim id))))
    (user-error "Kargu: model metadata requires a model identifier"))
  (cons (kargu-model-store--provider provider) (copy-sequence (string-trim id))))

(defun kargu-model-store--find (key exact)
  "Resolve KEY, allowing a unique short alias unless EXACT is non-nil."
  (or (gethash key kargu--model-metadata-table)
      (unless (or exact (string-search "/" (cdr key)))
        (let ((suffix (concat "/" (cdr key))) found)
          (maphash
           (lambda (candidate entry)
             (when (and (consp candidate) (kargu-model-entry-p entry)
                        (equal (car candidate) (car key))
                        (string-suffix-p suffix (cdr candidate)))
               (setq found (if found :ambiguous entry))))
           kargu--model-metadata-table)
          found))))

(defun kargu-model-store--effective (entry)
  "Return a native record applying ENTRY's overrides to a copy of its data."
  (let* ((raw (kargu-json-to-record (kargu-model-entry-data entry)))
         (data (if (hash-table-p raw) nil raw))
         (plist-p (and (consp data) (keywordp (car data)))))
    (dolist (pair (kargu-model-entry-overrides entry))
      (setq data
            (if plist-p
                (plist-put data (intern (concat ":" (car pair)))
                           (copy-tree (cdr pair) t))
              (cons (copy-tree pair t)
                    (cl-remove-if (lambda (cell) (equal (car-safe cell) (car pair))) data)))))
    data))

(cl-defun kargu-model-store-get (provider id &key exact)
  "Read ID's metadata under explicit PROVIDER, or nil when unavailable.
EXACT refuses aliases; ambiguous short names always return nil."
  (let ((entry (kargu-model-store--find (kargu-model-store--key provider id) exact)))
    (when (kargu-model-entry-p entry) (kargu-model-store--effective entry))))

(defun kargu-model-store-put (provider id data)
  "Publish DATA for PROVIDER's canonical ID, preserving local overrides."
  (let* ((key (kargu-model-store--key provider id))
         (old (gethash key kargu--model-metadata-table))
         (entry (kargu-model-store--entry
                 :provider (car key) :id (cdr key)
                 :data (kargu-json-to-record data)
                 :overrides (and old (kargu-model-entry-overrides old)))))
    (puthash key entry kargu--model-metadata-table)
    (kargu-model-store--effective entry)))

(defun kargu-model-store-retain (provider ids)
  "Retain catalog metadata only for PROVIDER's freshly advertised IDS.
Removed models lose raw catalog data, but keep explicit local overrides.
An empty successful catalog clears all raw data for that provider alone."
  (let ((provider (kargu-model-store--provider provider))
        (keep (make-hash-table :test #'equal)))
    (dolist (id ids) (puthash id t keep))
    (maphash
     (lambda (key entry)
       (when (and (kargu-model-entry-p entry)
                  (equal (kargu-model-entry-provider entry) provider)
                  (not (gethash (kargu-model-entry-id entry) keep)))
         (if (kargu-model-entry-overrides entry)
             (puthash key (kargu-model-store--entry
                           :provider provider :id (kargu-model-entry-id entry)
                           :overrides (kargu-model-entry-overrides entry))
                      kargu--model-metadata-table)
           (remhash key kargu--model-metadata-table))))
     kargu--model-metadata-table)))

(cl-defun kargu-model-store-set-property (provider id &key property value)
  "Override PROPERTY with VALUE for PROVIDER's ID across catalog refreshes.
A unique alias updates its canonical record; ambiguous aliases are refused."
  (unless (and (stringp property) (not (string-empty-p property)))
    (user-error "Kargu: metadata property must be a nonempty string"))
  (when (equal property "provider")
    (user-error "Kargu: a metadata property cannot transfer provider ownership"))
  (let* ((key (kargu-model-store--key provider id))
         (old (kargu-model-store--find key nil)))
    (when (eq old :ambiguous)
      (user-error "Kargu: ambiguous model alias; use its full catalog identifier"))
    (when old (setq key (cons (kargu-model-entry-provider old) (kargu-model-entry-id old))))
    (let ((entry (kargu-model-store--entry
                  :provider (car key) :id (cdr key)
                  :data (and old (kargu-model-entry-data old))
                  :overrides (cons (cons property (copy-tree value t))
                                   (cl-remove-if
                                    (lambda (pair) (equal (car pair) property))
                                    (and old (kargu-model-entry-overrides old)))))))
      (puthash key entry kargu--model-metadata-table)
      (kargu-model-store--effective entry))))

(provide 'kargu/models/store)
;;; store.el ends here
