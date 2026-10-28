;;; document.el --- Live editor transaction primitives -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Platform facts and consuming buffer transactions for the native edit owner.
;; These primitives neither authorize edits nor classify their domain outcome.
;; The issued-operation controller must retain its activity fence through return,
;; including reentrant save/change hooks, and through native receipt settlement.
;; No tool consumer uses this adapter until that controller is connected.

;;; Code:

(require 'cl-lib)
(require 'map)
(require 'kargu/config/connection)

(defconst kargu-bridge-edit-document--text-bytes (* 4 1024 1024)
  "Maximum UTF-8 bytes in one observed editor document.")
(defconst kargu-bridge-edit-document--diff-cost 1000000
  "Comparison cost limit for the editor's marker-preserving replacement.")

(define-error 'kargu-bridge-edit-document-conflict "Editor document changed")
(define-error 'kargu-bridge-edit-document-revoked "Editor issuance revoked")
(define-error 'kargu-bridge-edit-document-limit "Editor document exceeds text limit")
(define-error 'kargu-bridge-edit-document-consumed "Editor observation already consumed")

(defvar-local kargu-bridge-edit-document--id nil
  "Pair of owning buffer and opaque identity; never an edit authorization.")
(put 'kargu-bridge-edit-document--id 'permanent-local t)

(cl-defstruct (kargu-bridge-edit-document
               (:constructor kargu-bridge-edit-document--make))
  "Detached platform observation; USED prevents transaction replay."
  buffer id path truename tick text coding dirty read-only disk used)

(cl-defstruct (kargu-bridge-edit-document-change
               (:constructor kargu-bridge-edit-document-change--make))
  "Observed transaction progress, including failures and failed observation.
STAGE records entry into editor primitives, never an applied verdict.
WRITE-TICK precedes save hooks; AFTER includes their actual buffer effects."
  before after (stage :not-entered) write-tick failure observation-failure)

(cl-defstruct (kargu-bridge-edit-disk
               (:constructor kargu-bridge-edit-disk--make))
  "Local stat identity, excluding atime as in native DiskVersion."
  device inode bytes mtime ctime)

(defun kargu-bridge-edit-document--text (text)
  "Return a detached plain TEXT within the native UTF-8 limit."
  (unless (and (stringp text)
               (<= (length text) kargu-bridge-edit-document--text-bytes)
               (<= (string-bytes (encode-coding-string text 'utf-8-unix))
                   kargu-bridge-edit-document--text-bytes))
    (signal 'kargu-bridge-edit-document-limit nil))
  (substring-no-properties text))

(defun kargu-bridge-edit-document--disk (path)
  "Observe local PATH without opening file contents or following a final link."
  (when (file-remote-p path)
    (signal 'kargu-bridge-edit-document-conflict nil))
  (let ((attributes (file-attributes path 'integer)))
    (when (and attributes (file-attribute-type attributes))
      (signal 'kargu-bridge-edit-document-conflict nil))
    (when attributes
      (kargu-bridge-edit-disk--make
       :device (file-attribute-device-number attributes)
       :inode (file-attribute-inode-number attributes)
       :bytes (file-attribute-size attributes)
       :mtime (file-attribute-modification-time attributes)
       :ctime (file-attribute-status-change-time attributes)))))

(defun kargu-bridge-edit-document--read-only-p ()
  "Whether any part of the widened current document is read-only."
  (save-restriction
    (widen)
    (or buffer-read-only
        (not (null (text-property-not-all (point-min) (point-max) 'read-only nil))))))

(defun kargu-bridge-edit-document-capture (buffer)
  "Capture bounded, widened BUFFER facts without changing its view.
Dirty/read-only facts are reported; transaction entry rejects either condition."
  (with-current-buffer buffer
    (unless (and buffer-file-name (not (buffer-base-buffer)))
      (signal 'kargu-bridge-edit-document-conflict nil))
    (save-restriction
      (widen)
      (when (> (buffer-size) kargu-bridge-edit-document--text-bytes)
        (signal 'kargu-bridge-edit-document-limit nil))
      (unless (eq (car-safe kargu-bridge-edit-document--id) buffer)
        (setq kargu-bridge-edit-document--id
              (cons buffer (concat "editor_document_" (kargu-random-uuid)))))
      (kargu-bridge-edit-document--make
       :buffer buffer :id (cdr kargu-bridge-edit-document--id)
       :path (expand-file-name buffer-file-name)
       :truename (file-truename buffer-file-name)
       :tick (buffer-chars-modified-tick)
       :text (kargu-bridge-edit-document--text (buffer-string))
       :coding buffer-file-coding-system :dirty (buffer-modified-p)
       :read-only (kargu-bridge-edit-document--read-only-p)
       :disk (kargu-bridge-edit-document--disk buffer-file-name)))))

(defun kargu-bridge-edit-document--location-current-p (document)
  "Check live identity, path resolution and coding against DOCUMENT."
  (and (eq (car-safe kargu-bridge-edit-document--id) (current-buffer))
       (equal (cdr kargu-bridge-edit-document--id)
              (kargu-bridge-edit-document-id document))
       buffer-file-name
       (equal (expand-file-name buffer-file-name)
              (kargu-bridge-edit-document-path document))
       (equal (file-truename buffer-file-name)
              (kargu-bridge-edit-document-truename document))
       (eq buffer-file-coding-system (kargu-bridge-edit-document-coding document))))

(defun kargu-bridge-edit-document-check (document)
  "Reject DOCUMENT if any captured clean-buffer or disk fact changed.
This is a platform observation, not the native approval decision or a lock."
  (unless (buffer-live-p (kargu-bridge-edit-document-buffer document))
    (signal 'kargu-bridge-edit-document-conflict nil))
  (with-current-buffer (kargu-bridge-edit-document-buffer document)
    (unless (and (not (kargu-bridge-edit-document-dirty document))
                 (not (kargu-bridge-edit-document-read-only document))
                 (not (buffer-modified-p))
                 (not (kargu-bridge-edit-document--read-only-p))
                 (kargu-bridge-edit-document--location-current-p document)
                 (= (buffer-chars-modified-tick)
                    (kargu-bridge-edit-document-tick document))
                 (equal (kargu-bridge-edit-document--disk buffer-file-name)
                        (kargu-bridge-edit-document-disk document)))
      (signal 'kargu-bridge-edit-document-conflict nil))))

(defun kargu-bridge-edit-document--replace (change source)
  "Record CHANGE while replacing from detached SOURCE in one undo group."
  (setf (kargu-bridge-edit-document-change-stage change) :replacing)
  (undo-boundary)
  (atomic-change-group
    (replace-buffer-contents source nil kargu-bridge-edit-document--diff-cost))
  (undo-boundary)
  (setf (kargu-bridge-edit-document-change-write-tick change)
        (buffer-chars-modified-tick)
        (kargu-bridge-edit-document-change-stage change) :replaced))

(defun kargu-bridge-edit-document--save (change check-issued)
  "Save after CHANGE only while CHECK-ISSUED still permits entry."
  (unless (funcall check-issued)
    (signal 'kargu-bridge-edit-document-revoked nil))
  (let ((before (kargu-bridge-edit-document-change-before change)))
    (unless (and (kargu-bridge-edit-document--location-current-p before)
                 (equal (kargu-bridge-edit-document--disk buffer-file-name)
                        (kargu-bridge-edit-document-disk before)))
      (signal 'kargu-bridge-edit-document-conflict nil)))
  (setf (kargu-bridge-edit-document-change-stage change) :saving)
  ;; Even a byte-identical empty new file must be created under explicit save.
  (unless (kargu-bridge-edit-document-disk
           (kargu-bridge-edit-document-change-before change))
    (set-buffer-modified-p t))
  (save-buffer)
  (setf (kargu-bridge-edit-document-change-stage change) :save-returned))

(defun kargu-bridge-edit-document--observe (change)
  "Attach final raw buffer facts or an explicit observation failure to CHANGE."
  (condition-case failure
      (setf (kargu-bridge-edit-document-change-after change)
            (kargu-bridge-edit-document-capture
             (kargu-bridge-edit-document-buffer
              (kargu-bridge-edit-document-change-before change))))
    ((error quit)
     (setf (kargu-bridge-edit-document-change-observation-failure change) failure))))

(cl-defun kargu-bridge-edit-document-replace (document text &key check-issued save)
  "Consume DOCUMENT to replace with TEXT, optionally SAVE, recording raw facts.
CHECK-ISSUED is the owning controller's live issuance guard, required at entry
and before save.  That controller must hold its fence until actual return.
Failures after entry are observations, never permission to replay or restore.
The caller reports them to Rust, which owns outcome and rollback decisions."
  (when (kargu-bridge-edit-document-used document)
    (signal 'kargu-bridge-edit-document-consumed nil))
  (setf (kargu-bridge-edit-document-used document) t)
  (let ((change (kargu-bridge-edit-document-change--make :before document)))
    (condition-case failure
        (let ((text (kargu-bridge-edit-document--text text)))
          (kargu-bridge-edit-document-check document)
          (unless (and (functionp check-issued) (funcall check-issued))
            (signal 'kargu-bridge-edit-document-revoked nil))
          ;; The controller callback can yield or run arbitrary editor hooks.
          (kargu-bridge-edit-document-check document)
          (with-temp-buffer
            (insert text)
            (let ((source (current-buffer)))
              (with-current-buffer (kargu-bridge-edit-document-buffer document)
                (save-mark-and-excursion
                  (save-restriction
                    (widen)
                    (kargu-bridge-edit-document--replace change source)
                    (when save
                      (kargu-bridge-edit-document--save change check-issued))))))))
      ((error quit)
       (setf (kargu-bridge-edit-document-change-failure change) failure)))
    (kargu-bridge-edit-document--observe change)
    change))

(defun kargu-bridge-edit-document--disk-facts (disk)
  "Encode observed DISK in the native stat schema without reading contents."
  (if (null disk)
      (map-into '(("kind" . "absent")) 'hash-table)
    (map-into
     `(("kind" . "file")
       ("version" . ,(map-into
                      `(("device" . ,(kargu-bridge-edit-disk-device disk))
                        ("inode" . ,(kargu-bridge-edit-disk-inode disk))
                        ("bytes" . ,(kargu-bridge-edit-disk-bytes disk))
                        ("mtime_ns" . ,(number-to-string
                                        (car (time-convert (kargu-bridge-edit-disk-mtime disk)
                                                           1000000000))))
                        ("ctime_ns" . ,(number-to-string
                                        (car (time-convert (kargu-bridge-edit-disk-ctime disk)
                                                           1000000000)))))
                      'hash-table)))
     'hash-table)))

(defun kargu-bridge-edit-document-facts (document)
  "Encode detached DOCUMENT facts for native capture or preflight.
This reports observations without asserting approval, freshness or an outcome."
  (map-into
   `(("id" . ,(kargu-bridge-edit-document-id document))
     ("tick" . ,(kargu-bridge-edit-document-tick document))
     ("bytes" . ,(string-bytes (encode-coding-string
                               (kargu-bridge-edit-document-text document) 'utf-8-unix)))
     ("coding" . ,(symbol-name (kargu-bridge-edit-document-coding document)))
     ("dirty" . ,(if (kargu-bridge-edit-document-dirty document) t :json-false))
     ("read_only" . ,(if (kargu-bridge-edit-document-read-only document) t :json-false))
     ("disk" . ,(kargu-bridge-edit-document--disk-facts
                 (kargu-bridge-edit-document-disk document))))
   'hash-table))

(defun kargu-bridge-edit-document-witness (document file)
  "Encode DOCUMENT as native preflight witness for FILE's zero-based index.
Hash the observed buffer text; never echo the native proposal's base hash as
an assertion about a potentially stale editor buffer."
  (map-into
   `(("file" . ,file)
     ("base_hash" . ,(secure-hash 'sha256
                                 (encode-coding-string
                                  (kargu-bridge-edit-document-text document) 'utf-8-unix)))
     ("document" . ,(kargu-bridge-edit-document-facts document)))
   'hash-table))

(provide 'kargu/bridge/edit/document)
;;; document.el ends here
