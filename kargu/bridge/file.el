;;; file.el --- Scoped RAM capture and recheck for native read_file -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Native read_file pins either a live document or an observed absence of a
;; visiting buffer.  Capture and recheck run outside the process filter.  Disk
;; IO, argument/range policy, numbering and result classification belong to Rust.

;;; Code:

(require 'cl-lib)
(require 'kargu/bridge/sensor)
(require 'kargu/files/snapshot)

(cl-defstruct (kargu-bridge-file-observation (:constructor kargu-bridge-file--make))
  "Captured native invocation and its source resource; no write authority."
  params entry owner session path buffer stamp)

(defun kargu-bridge-file--target (root relative)
  "Resolve RELATIVE under ROOT, refusing remote or external editor resources."
  (unless (and (stringp root) (stringp relative) (not (file-remote-p root))
               (not (file-remote-p relative)) (not (file-name-absolute-p relative)))
    (error "Invalid native file capture path"))
  (let ((path (expand-file-name relative root)))
    (unless (file-in-directory-p (file-truename path) root)
      (error "Native file capture is outside its root"))
    path))

(defun kargu-bridge-file--same-owner-p (connection observation params)
  "Check OBSERVATION's exact owner identity on CONNECTION against PARAMS."
  (let ((original (kargu-bridge-file-observation-params observation))
        (owner (kargu-bridge-file-observation-owner observation)))
    (and (eq (kargu-bridge-session-owned-entry connection params)
             (kargu-bridge-file-observation-entry observation))
         (buffer-live-p owner)
         (eq (kargu-session-context owner) (kargu-bridge-file-observation-session observation))
         (cl-every (lambda (key) (kargu-bridge-sensor--equal-p
                                  (gethash key params) (gethash key original)))
                   '("request_id" "connection_epoch" "scope" "call_id")))))

(defun kargu-bridge-file--same-call-p (connection observation params)
  "Check OBSERVATION still owns immutable PARAMS on exact CONNECTION."
  (let ((original (kargu-bridge-file-observation-params observation)))
    (and (kargu-bridge-file--same-owner-p connection observation params)
         (cl-every (lambda (key) (kargu-bridge-sensor--equal-p
                                  (gethash key params) (gethash key original)))
                   '("root" "tool" "arguments")))))

(defun kargu-bridge-file--release (connection call-id)
  "Release CALL-ID's pure observation on CONNECTION."
  (remhash call-id (kargu-bridge-connection-file-observations connection))
  (remhash (concat "file:" call-id) (kargu-bridge-connection-reverse-cleanups connection)))

(defun kargu-bridge-file-capture (connection id params)
  "Capture an exact native read_file source for ID/PARAMS on CONNECTION."
  (let ((call-id (and (hash-table-p params) (gethash "call_id" params))) registered)
    (condition-case nil
        (let* ((entry (kargu-bridge-session-owned-entry connection params))
               (intent (and entry (kargu-bridge--pending-session-intent entry)))
               (owner (and entry (kargu-bridge--pending-owner entry)))
               (root (and intent (gethash "root" intent)))
               (spec (gethash "capture" params))
               (table (kargu-bridge-connection-file-observations connection)))
          (unless (and entry (buffer-live-p owner) (hash-table-p spec)
                       (equal (gethash "tool" params) "read_file")
                       (stringp call-id) (not (string-empty-p call-id))
                       (stringp root) (not (file-remote-p root))
                       (equal (directory-file-name (file-truename root))
                              (directory-file-name (gethash "root" params)))
                       (not (gethash call-id table))
                       (< (+ (hash-table-count table)
                             (hash-table-count (kargu-bridge-connection-sensor-calls connection)))
                          kargu-bridge--max-pending))
            (error "Unowned native file capture"))
          (let* ((path (kargu-bridge-file--target (gethash "root" params) (gethash "path" spec)))
                 (buffer (find-buffer-visiting path))
                 (resource (and (buffer-live-p buffer)
                                (kargu-bridge-sensor--document buffer root)))
                 (stamp (if resource
                            (kargu-bridge--object "kind" "editor" "document" (gethash "document" resource)
                                                  "dirty" (with-current-buffer buffer
                                                            (if (buffer-modified-p) t :json-false)))
                          (kargu-bridge--object "kind" "disk")))
                 (source (when resource
                           (kargu-file-capture-live buffer (gethash "from" spec)
                                                   (gethash "scan_chars" spec) (gethash "output_chars" spec))))
                 (observation (kargu-bridge-sensor--copy stamp))
                 (result (kargu-bridge--object "scope" (gethash "scope" params) "call_id" call-id
                                               "observation" observation)))
            (when source
              (remhash "kind" source)
              (puthash "source" source observation)
              ;; Keep native policy unchanged. A shorter RAM prefix explicitly
              ;; remains incomplete and uses the same native excerpt renderer.
              (let ((limit (kargu-bridge-connection-frame-limit connection)))
                (while (and (> (string-bytes (json-serialize
                                             (kargu-bridge--object "jsonrpc" "2.0" "id" id "result" result)
                                             :false-object :json-false :null-object :json-null)) limit)
                            (> (length (gethash "text" source)) 0))
                  (puthash "text" (substring (gethash "text" source) 0 (/ (length (gethash "text" source)) 2)) source)
                  (puthash "complete" :json-false source))
                (when (> (string-bytes (json-serialize
                                       (kargu-bridge--object "jsonrpc" "2.0" "id" id "result" result)
                                       :false-object :json-false :null-object :json-null)) limit)
                  (error "Native snapshot metadata exceeds frame limit"))))
            (puthash call-id (kargu-bridge-file--make
                             :params (kargu-bridge-sensor--copy params) :entry entry :owner owner
                             :session (kargu-session-context owner) :path path :buffer buffer :stamp stamp) table)
            (setq registered t)
            (puthash (concat "file:" call-id)
                     (cons (gethash "request_id" params)
                           (lambda () (kargu-bridge-file--release connection call-id)))
                     (kargu-bridge-connection-reverse-cleanups connection))
            (kargu-bridge-sensor--reply connection id result)))
      ((error quit)
       (when registered (kargu-bridge-file--release connection call-id))
       (kargu-bridge-sensor--error connection id)))))

(defun kargu-bridge-file-validate (connection id params)
  "Recheck the captured source for native ID/PARAMS on CONNECTION."
  (let* ((call-id (and (hash-table-p params) (gethash "call_id" params)))
         (observation (gethash call-id (kargu-bridge-connection-file-observations connection)))
         (owned (condition-case nil
                    (and observation (kargu-bridge-file--same-call-p connection observation params))
                  ((error quit) nil)))
         (current (condition-case nil
                      (and owned
                           (kargu-bridge-sensor--equal-p
                            (gethash "observation" params) (kargu-bridge-file-observation-stamp observation))
                           (let* ((original (kargu-bridge-file-observation-params observation))
                                  (root (gethash "root" original))
                                  (path (kargu-bridge-file--target root (gethash "path" (gethash "capture" original))))
                                  (buffer (kargu-bridge-file-observation-buffer observation))
                                  (now (find-buffer-visiting path)))
                             (and (equal path (kargu-bridge-file-observation-path observation))
                                  (if buffer
                                      (and (buffer-live-p buffer) (eq now buffer)
                                           (eq (gethash "dirty" (kargu-bridge-file-observation-stamp observation))
                                               (with-current-buffer buffer (if (buffer-modified-p) t :json-false)))
                                           (kargu-bridge-sensor--equal-p
                                            (gethash "document" (kargu-bridge-file-observation-stamp observation))
                                            (gethash "document" (kargu-bridge-sensor--document buffer root))))
                                    (null now)))))
                    ((error quit) nil))))
    (when owned (kargu-bridge-file--release connection call-id))
    (kargu-bridge-sensor--reply connection id
                                (kargu-bridge--object "scope" (gethash "scope" params)
                                                     "call_id" call-id "current" (if current t :json-false)))))

(defun kargu-bridge-file-release (connection params)
  "Release only PARAMS' owned native file observation on CONNECTION."
  (let* ((call-id (and (hash-table-p params) (gethash "call_id" params)))
         (observation (gethash call-id (kargu-bridge-connection-file-observations connection))))
    (when (and observation (kargu-bridge-file--same-owner-p connection observation params))
      (kargu-bridge-file--release connection call-id))))

(provide 'kargu/bridge/file)
;;; file.el ends here
