;;; transfer.el --- Bounded native metadata upload and download -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Exact-offset delivery and protocol validation only.  No metadata semantics.
;; Retain allocation callbacks after cancellation to abort late acquisitions.

;;; Code:

(require 'kargu/bridge/models/state)

(declare-function kargu-bridge-models--complete "kargu/bridge/models" (ticket view failure))

(defun kargu-bridge-models--call (ticket method arguments callback)
  "Call METHOD with captured ARGUMENTS for TICKET, delivering CALLBACK safely."
  (let ((service (kargu-bridge-model-ticket-service ticket)) delivered)
    (kargu-bridge-call
     (kargu-bridge-models-connection service) method
     (kargu-bridge--object "scope" (kargu-bridge-application--copy-scope
                                    (kargu-bridge-models-scope service))
                           "arguments" arguments)
     (lambda (result failure)
       (unless delivered
         (setq delivered t)
         (unless (kargu-bridge-model-ticket-released ticket)
	   (condition-case nil
               (funcall callback result failure)
             ((error quit)
              (let ((failure (kargu-bridge--fault "invalid_metadata_projection")))
		(if (and (kargu-bridge-model-ticket-upload ticket)
			 (not (kargu-bridge-model-ticket-commit-sent ticket))
			 (not (eq (kargu-bridge-model-ticket-phase ticket) :aborting)))
                    (kargu-bridge-models--abort ticket failure)
		  (kargu-bridge-models--complete ticket nil failure)))))))))))

(defun kargu-bridge-models--valid-p (ticket)
  "Check TICKET's captured resources and exact lease before another operation."
  (and (null (kargu-bridge-model-ticket-cancel-reason ticket))
       (kargu-bridge-models--current-p (kargu-bridge-model-ticket-service ticket))
       (or (null (kargu-bridge-model-ticket-owner ticket))
           (buffer-live-p (kargu-bridge-model-ticket-owner ticket)))
       (condition-case nil
           (or (null (kargu-bridge-model-ticket-valid-p ticket))
               (funcall (kargu-bridge-model-ticket-valid-p ticket)))
         ((error quit) nil))))

(defun kargu-bridge-models--abort (ticket failure)
  "Drain TICKET's exact upload before reporting FAILURE to the queue."
  (if (or (null (kargu-bridge-model-ticket-upload ticket))
          (kargu-bridge-model-ticket-commit-sent ticket))
      (kargu-bridge-models--complete ticket nil failure)
    (setf (kargu-bridge-model-ticket-phase ticket) :aborting)
    (kargu-bridge-models--call
     ticket "models/abort"
     (kargu-bridge--object "upload_id" (kargu-bridge-model-ticket-upload ticket))
     (lambda (result fault)
       (when (or fault (not (equal (and (hash-table-p result) (gethash "status" result)) "aborted")))
         (setf (kargu-bridge-models-fault (kargu-bridge-model-ticket-service ticket))
               (or fault (kargu-bridge--fault "metadata_abort_unconfirmed"))))
       (kargu-bridge-models--complete ticket nil failure)))))

(defun kargu-bridge-models--continue (ticket function)
  "Continue TICKET with FUNCTION, or abort a revoked submission."
  (if (kargu-bridge-models--valid-p ticket) (funcall function)
    (kargu-bridge-models--abort ticket (or (kargu-bridge-model-ticket-cancel-reason ticket)
                                           (kargu-bridge--fault "stale_metadata_owner")))))

(defun kargu-bridge-models--read (ticket)
  "Download one exact committed-revision snapshot page for TICKET."
  (kargu-bridge-models--continue
   ticket
   (lambda ()
     (setf (kargu-bridge-model-ticket-phase ticket) :reading)
     (kargu-bridge-models--call
      ticket "models/read"
      (kargu-bridge--object "revision" (kargu-bridge-model-ticket-revision ticket)
                            "offset" (kargu-bridge-model-ticket-read-bytes ticket))
      (lambda (page failure)
        (if failure (kargu-bridge-models--complete ticket nil failure)
          (let* ((chunk (and (hash-table-p page) (gethash "chunk" page)))
                 (bytes (and (stringp chunk) (string-bytes chunk)))
                 (offset (kargu-bridge-model-ticket-read-bytes ticket))
                 (total (kargu-bridge-model-ticket-total ticket)))
            (unless (and bytes (<= bytes 16384)
                         (equal (gethash "revision" page) (kargu-bridge-model-ticket-revision ticket))
                         (equal (gethash "offset" page) offset)
                         (equal (gethash "next_offset" page) (+ offset bytes))
                         (equal (gethash "total_bytes" page) total)
                         (<= (+ offset bytes) total)
                         (memq (gethash "done" page) '(t :json-false))
                         (if (eq (gethash "done" page) t) (= (+ offset bytes) total) (> bytes 0)))
              (error "Invalid native metadata page"))
            (push chunk (kargu-bridge-model-ticket-chunks ticket))
            (setf (kargu-bridge-model-ticket-read-bytes ticket) (+ offset bytes))
            (if (not (eq (gethash "done" page) t)) (kargu-bridge-models--read ticket)
              (let* ((body (apply #'concat (nreverse (kargu-bridge-model-ticket-chunks ticket))))
                     (view (json-parse-string body :object-type 'hash-table :array-type 'array
                                              :null-object :json-null :false-object :json-false)))
                (unless (and (hash-table-p view)
                             (hash-table-p (gethash "defaults" view))
                             (hash-table-p (gethash "display" (gethash "defaults" view)))
                             (equal (gethash "revision" view) (kargu-bridge-model-ticket-revision ticket))
                             (cl-every (lambda (key) (vectorp (gethash key view)))
                                       '("records" "aliases" "catalogs" "refusals"))
                             (<= (length (gethash "records" view)) 20000)
                             (<= (length (gethash "aliases" view)) 20000)
                             (<= (length (gethash "catalogs" view)) 256)
                             (<= (length (gethash "refusals" view)) 20000))
                  (error "Invalid native metadata snapshot"))
                (kargu-bridge-models--continue
                 ticket (lambda () (kargu-bridge-models--complete ticket view nil))))))))))))

(defun kargu-bridge-models--commit (ticket)
  "Commit TICKET once; a lost receipt never authorizes the old UI cache."
  (kargu-bridge-models--continue
   ticket
   (lambda ()
     (setf (kargu-bridge-model-ticket-phase ticket) :committing
           (kargu-bridge-model-ticket-commit-sent ticket) t)
     (kargu-bridge-models--call
      ticket "models/commit"
      (kargu-bridge--object "upload_id" (kargu-bridge-model-ticket-upload ticket))
      (lambda (result failure)
        (if failure
            (progn
              ;; These closed native failures guarantee commit did not occur.
              (when (member (and (hash-table-p failure) (gethash "status" (gethash "data" failure)))
                            '("invalid_metadata" "ambiguous_model" "resource_limit"))
                (setf (kargu-bridge-model-ticket-commit-sent ticket) nil
                      (kargu-bridge-model-ticket-upload ticket) nil))
              (kargu-bridge-models--complete ticket nil failure))
          (let ((revision (and (hash-table-p result) (gethash "revision" result)))
                (total (and (hash-table-p result) (gethash "total_bytes" result))))
            (unless (and (natnump revision) (= revision (1+ (kargu-bridge-model-ticket-revision ticket)))
                         (natnump total) (<= 1 total kargu-bridge-models--view-limit))
              (error "Invalid native metadata commit receipt"))
            (setf (kargu-bridge-model-ticket-revision ticket) revision
                  (kargu-bridge-model-ticket-total ticket) total)
            (kargu-bridge-models--read ticket))))))))

(defun kargu-bridge-models--append (ticket)
  "Append a UTF-8 bounded exact-offset fragment of TICKET's captured source."
  (kargu-bridge-models--continue
   ticket
   (lambda ()
     (let* ((source (kargu-bridge-model-ticket-source ticket))
            (start (kargu-bridge-model-ticket-position ticket))
            (end (min (length source) (+ start (kargu-bridge-model-ticket-max-chunk ticket))))
            (chunk (substring source start end)))
       (while (> (string-bytes chunk) (kargu-bridge-model-ticket-max-chunk ticket))
         (setq end (- end (max 1 (/ (+ 3 (- (string-bytes chunk)
                                            (kargu-bridge-model-ticket-max-chunk ticket))) 4)))
               chunk (substring source start end)))
       (if (= start end) (kargu-bridge-models--commit ticket)
         (setf (kargu-bridge-model-ticket-phase ticket) :appending)
         (kargu-bridge-models--call
          ticket "models/append"
          (kargu-bridge--object "upload_id" (kargu-bridge-model-ticket-upload ticket)
                                "offset" (kargu-bridge-model-ticket-offset ticket) "chunk" chunk)
          (lambda (result failure)
            (if failure (kargu-bridge-models--abort ticket failure)
              (unless (and (hash-table-p result)
                           (equal (gethash "upload_id" result) (kargu-bridge-model-ticket-upload ticket))
                           (equal (gethash "offset" result)
                                  (+ (kargu-bridge-model-ticket-offset ticket) (string-bytes chunk))))
                (error "Invalid native metadata upload acknowledgement"))
              (setf (kargu-bridge-model-ticket-offset ticket) (gethash "offset" result)
                    (kargu-bridge-model-ticket-position ticket) end)
              (kargu-bridge-models--append ticket)))))))))

(defun kargu-bridge-models--begin (ticket)
  "Acquire TICKET's native upload; retain late replies so they can be aborted."
  (kargu-bridge-models--continue
   ticket
   (lambda ()
     (let* ((service (kargu-bridge-model-ticket-service ticket))
            (revision (if (kargu-bridge-models--view service)
                          (gethash "revision" (kargu-bridge-models--view service)) 0)))
       (setf (kargu-bridge-model-ticket-phase ticket) :beginning
             (kargu-bridge-model-ticket-revision ticket) revision)
       (kargu-bridge-models--call
        ticket "models/begin"
        (kargu-bridge--object "provider" (kargu-bridge-model-ticket-provider ticket)
                              "revision" revision "effort_specs" (kargu-bridge-model-ticket-specs ticket))
        (lambda (result failure)
          (if failure (kargu-bridge-models--complete ticket nil failure)
            (let ((id (and (hash-table-p result) (gethash "upload_id" result)))
                  (limit (and (hash-table-p result) (gethash "max_chunk_bytes" result))))
              (unless (and (stringp id) (string-prefix-p "metadata_" id) (<= (length id) 80))
                (error "Invalid native metadata upload identity"))
              (setf (kargu-bridge-model-ticket-upload ticket) (copy-sequence id))
              (unless (and (integerp limit) (<= 4 limit 16384)
                           (equal (gethash "revision" result) revision) (equal (gethash "offset" result) 0))
                (error "Invalid native metadata upload bounds"))
              (setf (kargu-bridge-model-ticket-max-chunk ticket) limit)
              (kargu-bridge-models--append ticket)))))))))

(defun kargu-bridge-models--head (ticket)
  "Read TICKET's existing native head before explicit reconciliation."
  (kargu-bridge-models--continue
   ticket
   (lambda ()
     (setf (kargu-bridge-model-ticket-phase ticket) :reconciling)
     (kargu-bridge-models--call
      ticket "models/snapshot" (kargu-bridge--object)
      (lambda (head failure)
        (if failure (kargu-bridge-models--complete ticket nil failure)
          (let ((revision (and (hash-table-p head) (gethash "revision" head)))
                (total (and (hash-table-p head) (gethash "total_bytes" head))))
            (unless (and (natnump revision) (natnump total)
                         (<= 1 total kargu-bridge-models--view-limit))
              (error "Invalid native metadata head"))
            (setf (kargu-bridge-model-ticket-revision ticket) revision
                  (kargu-bridge-model-ticket-total ticket) total)
            (kargu-bridge-models--read ticket))))))))

(provide 'kargu/bridge/models/transfer)
;;; transfer.el ends here
