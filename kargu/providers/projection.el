;;; projection.el --- Core-owned provider metadata projection -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Decode credential-free core data for existing editor readers.  The packaged
;; Rust manifest is the offline bootstrap; a live core publishes its own revision.
;; No endpoint catalog is duplicated in Lisp and loading does not start a process.

;;; Code:

(require 'json)
(require 'cl-lib)
(require 'kargu/providers/registry)

(defvar kargu-providers--projection nil
  "Last core-owned catalog snapshot; never includes credential values.")
(defvar kargu-providers--baseline (make-hash-table :test #'equal)
  "Prior baseline records, used only to preserve explicit editor overrides.")
(defvar kargu-providers-builtin-catalog nil
  "Compatibility view of core-owned built-in records, not a second catalog.")

(defun kargu-providers-wire-object (value &optional field)
  "Encode captured metadata VALUE as plain JSON data for core FIELD.
This is a DTO projection only; no format or request policy is evaluated."
  (cond
   ((memq value '(:session :app-url))
    (let ((object (make-hash-table :test #'equal)))
      (puthash "binding" (substring (symbol-name value) 1) object) object))
   ((null value)
    (cond ((memq field '(:stream :input-excludes-cache :cache-marker)) :json-false)
          ((memq field '(:blocks :copy-keys :detect)) [])
          (t :json-null)))
   ((eq value t) t)
   ((stringp value) (copy-sequence value))
   ((keywordp (car-safe value))
    (let ((object (make-hash-table :test #'equal)))
      (while value
        (let ((key (pop value)) (item (pop value)))
          (puthash (substring (symbol-name key) 1)
                   (kargu-providers-wire-object item key) object)))
      object))
   ((and (consp value) (stringp (car-safe (car value))))
    (let ((object (make-hash-table :test #'equal)))
      (dolist (pair value)
        (puthash (copy-sequence (car pair)) (kargu-providers-wire-object (cdr pair)) object))
      object))
   ((or (vectorp value) (listp value))
    (vconcat (mapcar #'kargu-providers-wire-object (append value nil))))
   ((symbolp value) (symbol-name value))
   (t value)))

(defun kargu-providers--decode (value &optional field)
  "Translate projection VALUE for legacy plist FIELD readers without evaluation."
  (cond
   ((hash-table-p value)
    (cond
     ((and (= (hash-table-count value) 1) (gethash "binding" value))
      (pcase (gethash "binding" value)
        ("app-url" :app-url) ("session" :session)
        (_ (error "Invalid provider header binding"))))
     ((memq field '(:extra-headers :default-headers :finish :usage))
      (let (pairs)
        (maphash (lambda (key item) (push (cons key (kargu-providers--decode item)) pairs)) value)
        (nreverse pairs)))
     (t (let (plist)
          (maphash (lambda (key item)
                     (let ((name (intern (concat ":" key))))
                       (setq plist (append plist (list name (kargu-providers--decode item name)))))) value)
          plist))))
   ((vectorp value) (mapcar (lambda (item) (kargu-providers--decode item field)) (append value nil)))
   ((and (stringp value)
         (or (memq field '(:format :auth :reasoning-shape :message-shape :response-shape :as :models-auth))
             (and (eq field :type) (member value '("list" "csv")))))
    (intern value))
   ((memq value '(:json-null :json-false)) nil)
   (t value)))

(defun kargu-providers-install-projection (snapshot)
  "Install core SNAPSHOT, retaining explicitly registered editor overrides."
  (unless (and (hash-table-p snapshot) (eql (gethash "schema_version" snapshot) 1)
               (vectorp (gethash "providers" snapshot))
               (<= 1 (length (gethash "providers" snapshot)) 512)
               (hash-table-p (gethash "formats" snapshot)))
    (error "Invalid provider catalog projection"))
  (let ((providers (kargu-providers--decode (gethash "providers" snapshot)))
        formats)
    (maphash (lambda (name definition)
               (push (cons (intern name) (kargu-providers--decode definition)) formats))
             (gethash "formats" snapshot))
    (dolist (provider providers)
      (let* ((id (plist-get provider :id)) (previous (gethash id kargu-providers--baseline))
             (current (gethash id kargu-providers--table)))
        (when (or (null current) (eq current previous))
          (apply #'kargu-register-provider provider)
          (puthash id (gethash id kargu-providers--table) kargu-providers--baseline))
        (provide (intern (concat "kargu/providers/" id)))))
    (dolist (format formats)
      (let ((current (assq (car format) kargu-provider-formats))
            (previous (and kargu-providers--projection
                           (gethash (symbol-name (car format)) (gethash "formats" kargu-providers--projection)))))
        (when (or (null current) (equal (cdr current) (kargu-providers--decode previous)))
          (setq kargu-provider-formats (cons format (assq-delete-all (car format) kargu-provider-formats))))))
    (setq kargu-providers-builtin-catalog providers
          kargu-providers--projection snapshot)))

(provide 'kargu/providers/projection)
;;; projection.el ends here
