;;; registry.el --- Explicit tool definition registry -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Every operation receives its registry explicitly.  Loading this module
;; creates no runtime instance and imports no API, session, agent or UI.
;; Definitions are trusted in-process records, not a plugin sandbox.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'seq)
(require 'kargu/contract/assert)

(cl-defstruct (kargu-tool-definition
               (:constructor kargu-tool-registry--definition-create))
  "Validated tool definition; consumers must treat nested data as read-only."
  (name nil :read-only t)
  (description nil :read-only t)
  (parameters nil :read-only t)
  (executor nil :read-only t)
  (policy nil :read-only t))

(cl-defstruct (kargu-tool-registry (:constructor kargu-tool-registry-create ()))
  "Owned registry of canonical definitions and flattened alias names."
  (entries (make-hash-table :test #'equal) :read-only t)
  (revision 0)
  (tasks (make-hash-table :test #'equal) :read-only t)
  (draining (make-hash-table :test #'equal) :read-only t))

(defun kargu-tool-registry-mark-draining (registry name)
  "Mark NAME as draining in REGISTRY."
  (kargu-tool-registry--assert registry)
  (kargu-contract-assert #'kargu-contract-non-empty-string-p name)
  (let ((canonical (kargu-tool-registry-canonical-name registry name)))
    (puthash canonical t (kargu-tool-registry-draining registry))))

(defun kargu-tool-registry-draining-p (registry name)
  "Return non-nil if NAME or its canonical tool is marked draining in REGISTRY."
  (kargu-tool-registry--assert registry)
  (let ((canonical (kargu-tool-registry-canonical-name registry name)))
    (gethash canonical (kargu-tool-registry-draining registry))))

(defun kargu-tool-registry-clear-draining (registry name)
  "Clear draining mark for NAME in REGISTRY."
  (kargu-tool-registry--assert registry)
  (let ((canonical (kargu-tool-registry-canonical-name registry name)))
    (remhash canonical (kargu-tool-registry-draining registry))))

(defun kargu-tool-registry--assert (registry)
  "Validate REGISTRY at entry."
  (kargu-contract-assert #'kargu-tool-registry-p registry))

(defun kargu-tool-registry--policy-p (policy)
  "Return non-nil when POLICY describes supported execution gates."
  (and (proper-list-p policy)
       (cl-evenp (length policy))
       (cl-loop for (key _value) on policy by #'cddr
                always (memq key '(:modes :available-p :needs-approval-p)))
       (proper-list-p (plist-get policy :modes))
       (seq-every-p #'kargu-contract-mode-p (plist-get policy :modes))
       (kargu-contract-callback-p (plist-get policy :available-p))
       (booleanp (plist-get policy :needs-approval-p))))

(cl-defun kargu-tool-registry-register
    (registry &key name description parameters executor policy)
  "Register or replace NAME in REGISTRY, returning its name.
DESCRIPTION, PARAMETERS, EXECUTOR and POLICY describe the tool.
Validate the complete definition before changing the registry.  Nested
schema and policy data remain borrowed, read-only values."
  (kargu-tool-registry--assert registry)
  (kargu-contract-assert #'kargu-contract-non-empty-string-p name)
  (kargu-contract-assert #'stringp description)
  (kargu-contract-assert #'kargu-contract-tool-schema-p parameters)
  (kargu-contract-assert #'kargu-contract-tool-executor-p executor)
  (kargu-contract-assert #'kargu-tool-registry--policy-p policy)
  (when (kargu-tool-registry-draining-p registry name)
    (error "Tool %s is still draining" name))
  (puthash name (kargu-tool-registry--definition-create
                 :name name :description description
                 :parameters (copy-tree parameters t)
                 :executor executor :policy (copy-tree policy t))
           (kargu-tool-registry-entries registry))
  (cl-incf (kargu-tool-registry-revision registry))
  name)

(defun kargu-tool-registry-names (registry)
  "Return a fresh list of registered names, including aliases, in REGISTRY."
  (kargu-tool-registry--assert registry)
  (hash-table-keys (kargu-tool-registry-entries registry)))

(defun kargu-tool-registry-count (registry)
  "Return the number of registered names in REGISTRY in constant time."
  (kargu-tool-registry--assert registry)
  (hash-table-count (kargu-tool-registry-entries registry)))

(defun kargu-tool-registry--find (registry name)
  "Find NAME in validated REGISTRY, resolving at most one alias."
  (let* ((entries (kargu-tool-registry-entries registry))
         (entry (gethash name entries)))
    (if (stringp entry) (gethash entry entries) entry)))

(defun kargu-tool-registry-find (registry name)
  "Return the canonical definition of NAME in REGISTRY, or nil."
  (kargu-tool-registry--assert registry)
  (kargu-contract-assert #'kargu-contract-non-empty-string-p name)
  (kargu-tool-registry--find registry name))

(defun kargu-tool-registry-canonical-name (registry name)
  "Resolve NAME in REGISTRY, retaining unknown names for error reporting."
  (let ((definition (kargu-tool-registry-find registry name)))
    (if definition (kargu-tool-definition-name definition) name)))

(defun kargu-tool-registry-alias (registry alias name)
  "Expose NAME in REGISTRY under ALIAS, returning ALIAS or nil.
Unknown targets are a no-op.  An alias may be redirected, but must not
overwrite a canonical definition.  Alias chains are flattened on entry."
  (kargu-tool-registry--assert registry)
  (kargu-contract-assert #'kargu-contract-non-empty-string-p alias)
  (kargu-contract-assert #'kargu-contract-non-empty-string-p name)
  (let* ((entries (kargu-tool-registry-entries registry))
         (definition (kargu-tool-registry--find registry name))
         (existing (gethash alias entries)))
    (when definition
      (let ((canonical (kargu-tool-definition-name definition)))
        (when (and (kargu-tool-definition-p existing)
                   (not (equal alias canonical)))
          (error "Tool alias %s would replace a canonical definition" alias))
        (unless (equal alias canonical)
          (puthash alias canonical entries)
          (cl-incf (kargu-tool-registry-revision registry)))
        alias))))

(defun kargu-tool-registry-set-policy (registry name policy)
  "Replace POLICY for canonical tool NAME and its aliases in REGISTRY.
Unknown names are rejected before any registry mutation."
  (kargu-tool-registry--assert registry)
  (kargu-contract-assert #'kargu-contract-non-empty-string-p name)
  (kargu-contract-assert #'kargu-tool-registry--policy-p policy)
  (let ((definition (kargu-tool-registry--find registry name)))
    (unless definition (error "No such tool: %s" name))
    (puthash (kargu-tool-definition-name definition)
             (kargu-tool-registry--definition-create
              :name (kargu-tool-definition-name definition)
              :description (kargu-tool-definition-description definition)
              :parameters (kargu-tool-definition-parameters definition)
              :executor (kargu-tool-definition-executor definition)
              :policy (copy-tree policy t))
             (kargu-tool-registry-entries registry))
    (cl-incf (kargu-tool-registry-revision registry)))
  policy)

(defun kargu-tool-registry-remove (registry name)
  "Remove NAME from REGISTRY and return non-nil if it existed.
Removing a canonical definition also removes all of its aliases.
Lookup and registration are constant time; canonical removal scans names."
  (kargu-tool-registry--assert registry)
  (kargu-contract-assert #'kargu-contract-non-empty-string-p name)
  (let* ((entries (kargu-tool-registry-entries registry))
         (entry (gethash name entries)))
    (when entry
      (if (kargu-tool-definition-p entry)
          (let (aliases)
            (maphash (lambda (key value)
                       (when (equal value name) (push key aliases))) entries)
            (dolist (alias aliases) (remhash alias entries))
            (remhash (kargu-tool-definition-name entry) (kargu-tool-registry-draining registry)))
        (remhash name (kargu-tool-registry-draining registry)))
      (remhash name entries)
      (cl-incf (kargu-tool-registry-revision registry))
      t)))

(provide 'kargu/tools/registry)
;;; registry.el ends here
