;;; sensor.el --- Scoped live editor observations for native runs -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Capture live resources before the native gate authorizes a call.  A source
;; owner, exact run, arguments and document tick must survive every yield.
;; Issued callbacks report quiescence once, including after owner cancellation.
;; Editor mutations use their dedicated receipt/lifecycle ports; a generic
;; tool callback cannot stand in for a verified edit or debugger effect.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'kargu/bridge/session)
(require 'kargu/bridge/edit/document)
(require 'kargu/core/session)

(declare-function kargu-lsp-snapshot-source "kargu/tools/lsp/snapshot" (&optional flush))
(declare-function kargu-bridge-sensor-symbols-call "kargu/bridge/sensor/symbols" (connection id params))
(declare-function kargu-lsp-get-diagnostics "kargu/tools/lsp/diagnostics" (path))
(declare-function kargu-lsp-get-project-diagnostics "kargu/tools/lsp/diagnostics" ())
(declare-function kargu-lsp-find-definition "kargu/tools/lsp/symbols" (name callback))
(declare-function kargu-lsp-build-skeleton "kargu/tools/lsp/skeleton" (&optional root callback))

(cl-defstruct (kargu-bridge-sensor-call (:constructor kargu-bridge-sensor--make))
  "One captured read resource; callbacks retain it until actual delivery."
  forward entry owner session params buffer resource state reverse-id)

(defun kargu-bridge-sensor--reply (connection id result)
  "Send the detached RESULT for ID on captured CONNECTION."
  (when (eq (kargu-bridge-status connection) 'ready)
    (let* ((envelope (kargu-bridge--object "jsonrpc" "2.0" "id" id "result" result))
           (limit (kargu-bridge-connection-frame-limit connection))
           (text (gethash "text" result)))
      (when (and (stringp text) (> (string-bytes (json-serialize envelope :false-object :json-false :null-object :json-null)) limit))
        (let ((low 0) (high (length text)) (notice "\n... (editor output truncated by IPC limit)"))
          (while (< low high)
            (let ((middle (/ (+ low high 1) 2)))
              (puthash "text" (concat (substring text 0 middle) notice) result)
              (if (<= (string-bytes (json-serialize envelope :false-object :json-false :null-object :json-null)) limit)
                  (setq low middle)
                (setq high (1- middle)))))
          (puthash "text" (concat (substring text 0 low) notice) result)))
      (condition-case nil
          (kargu-bridge--send connection envelope)
        ((error quit) (kargu-bridge--close connection "protocol_error"))))))

(defun kargu-bridge-sensor--error (connection id)
  "Refuse ID on CONNECTION without including source or exception text."
  (when (eq (kargu-bridge-status connection) 'ready)
    (kargu-bridge--send connection (kargu-bridge--object
                                  "jsonrpc" "2.0" "id" id
                                  "error" (kargu-bridge--object
                                           "code" -32000 "message" "Editor resource unavailable")))))

(defun kargu-bridge-sensor--copy (value)
  "Detach bounded wire VALUE with the bridge's JSON representation."
  (kargu-bridge--decode (json-serialize value :null-object :json-null :false-object :json-false)))

(defun kargu-bridge-sensor--equal-p (left right)
  "Compare bounded JSON LEFT and RIGHT by contents."
  (cond
   ((hash-table-p left)
    (and (hash-table-p right) (= (hash-table-count left) (hash-table-count right))
         (let ((same t))
           (maphash (lambda (key value)
                      (unless (kargu-bridge-sensor--equal-p value (gethash key right :missing))
                        (setq same nil))) left)
           same)))
   ((vectorp left)
    (and (vectorp right) (= (length left) (length right))
         (cl-every #'kargu-bridge-sensor--equal-p left right)))
   (t (equal left right))))

(defun kargu-bridge-sensor--document (buffer root)
  "Observe BUFFER's identity and tick within captured ROOT without reading text."
  (with-current-buffer buffer
    (unless (and buffer-file-name (not (buffer-base-buffer))
                 (not (file-remote-p buffer-file-name))
                 (file-in-directory-p (file-truename buffer-file-name) root))
      (error "Source outside native resource"))
    (unless (eq (car-safe kargu-bridge-edit-document--id) buffer)
      (setq kargu-bridge-edit-document--id
            (cons buffer (concat "editor_document_" (kargu-random-uuid)))))
    (kargu-bridge--object "kind" "document" "document"
                         (kargu-bridge--object
                          "path" (file-relative-name (expand-file-name buffer-file-name) root)
                          "document_id" (cdr kargu-bridge-edit-document--id)
                          "tick" (buffer-chars-modified-tick)))))

(defun kargu-bridge-sensor--same-call-p (connection call params)
  "Whether CALL owns immutable PARAMS on exact CONNECTION."
  (let* ((entry (kargu-bridge-session-owned-entry connection params))
         (original (kargu-bridge-sensor-call-params call))
         (owner (kargu-bridge-sensor-call-owner call)))
    (and (eq entry (kargu-bridge-sensor-call-entry call))
         (buffer-live-p owner)
         (eq (kargu-session-context owner) (kargu-bridge-sensor-call-session call))
         (cl-every (lambda (key) (kargu-bridge-sensor--equal-p
                                  (gethash key original) (gethash key params)))
                   '("request_id" "connection_epoch" "scope" "root" "call_id" "tool" "arguments" "parent_tool")))))

(defun kargu-bridge-sensor--language-document (buffer root &optional flush)
  "Capture BUFFER's exact language provider within ROOT; optionally FLUSH."
  (with-current-buffer buffer
    (when (> (buffer-size) (* 4 1024 1024)) (error "Symbol document exceeds capture limit"))
    ;; Refuse external resources before a provider flush can send live text.
    (kargu-bridge-sensor--document buffer root)
    (require 'kargu/tools/lsp/snapshot)
    (let* ((source (kargu-lsp-snapshot-source flush))
           (resource (kargu-bridge-sensor--document buffer root)))
      (puthash "kind" "language_document" resource)
      (puthash "source" source resource)
      resource)))

(defun kargu-bridge-sensor--live-p (connection call params)
  "Whether CALL still owns PARAMS and its exact live resource on CONNECTION."
  (let ((root (gethash "root" (kargu-bridge-sensor-call-params call))))
    (and (kargu-bridge-sensor--same-call-p connection call params)
         (buffer-live-p (kargu-bridge-sensor-call-buffer call))
         (kargu-bridge-sensor--equal-p
          (kargu-bridge-sensor-call-resource call)
          (kargu-bridge-sensor--language-document (kargu-bridge-sensor-call-buffer call) root)))))

(defun kargu-bridge-sensor-prepare-tool (connection id params)
  "Capture one live resource for ID/PARAMS on exact CONNECTION."
  (condition-case nil
      (let* ((entry (kargu-bridge-session-owned-entry connection params))
             (intent (and entry (kargu-bridge--pending-session-intent entry)))
             (owner (and entry (kargu-bridge--pending-owner entry)))
             (root (and intent (gethash "root" intent)))
             (tool (gethash "tool" params))
             (args (gethash "arguments" params))
             (call-id (gethash "call_id" params))
             (calls (kargu-bridge-connection-sensor-calls connection)))
        (unless (and entry (buffer-live-p owner) (stringp root)
                     (not (file-remote-p root))
                     (equal (directory-file-name (file-truename root))
                            (directory-file-name (gethash "root" params)))
                     (stringp call-id) (not (string-empty-p call-id))
                     (hash-table-p args)
                     (member tool '("read_file_symbols" "read_symbol"
                                    "lsp_diagnostics" "lsp_find_symbol" "lsp_project_skeleton"))
                     (or (member tool (append (gethash "editor_available" intent) nil))
                         (and (equal tool "read_file_symbols")
                              (equal (gethash "parent_tool" params) "edit_by_lsp")
                              (member "edit_by_lsp" (append (gethash "editor_available" intent) nil))))
                     (< (hash-table-count calls) kargu-bridge--max-pending)
                     (not (gethash call-id calls)))
          (error "Unowned resource request"))
        (let* ((path (gethash "file_path" args))
               (buffer (if (and (stringp path) (not (string-empty-p path)))
                           (find-buffer-visiting (expand-file-name path root)) owner))
               (resource
                (cond
                 ((member tool '("read_file_symbols" "read_symbol"))
                  (unless (buffer-live-p buffer) (error "Live document unavailable"))
                  (kargu-bridge-sensor--language-document buffer root t))
                 ((member tool '("lsp_diagnostics" "lsp_find_symbol" "lsp_project_skeleton"))
                  (if (buffer-live-p buffer)
                      (condition-case nil
                          (kargu-bridge-sensor--document buffer root)
                        (error (kargu-bridge--object "kind" "workspace")))
                    (kargu-bridge--object "kind" "workspace")))
                 (t (kargu-bridge--object "kind" "workspace"))))
               (captured (kargu-bridge-sensor--copy params)))
          (unless resource (error "Live document unavailable"))
          (puthash call-id (kargu-bridge-sensor--make
                           :forward (gethash "request_id" params) :entry entry :owner owner
                           :session (kargu-session-context owner) :params captured :buffer buffer
                           :resource resource :state :prepared) calls)
          (puthash (concat "sensor:" call-id)
                   (cons (gethash "request_id" params)
                         (lambda ()
                           (let ((call (gethash call-id calls)))
                             (when call
                               (if (eq (kargu-bridge-sensor-call-state call) :issued)
                                   (setf (kargu-bridge-sensor-call-state call) :cancelled)
                                 (remhash call-id calls)
                                 (remhash (concat "sensor:" call-id)
                                          (kargu-bridge-connection-reverse-cleanups connection)))))))
                   (kargu-bridge-connection-reverse-cleanups connection))
          (kargu-bridge-sensor--reply
           connection id (kargu-bridge--object "scope" (gethash "scope" captured)
                                              "call_id" call-id "resource" resource))))
    ((error quit) (kargu-bridge-sensor--error connection id))))

(defun kargu-bridge-sensor-approve-tool (connection id params)
  "Approve or refuse tool approval request for ID/PARAMS on CONNECTION."
  (let* ((call-id (gethash "call_id" params))
         (scope (gethash "scope" params)))
    (kargu-bridge-sensor--reply
     connection id
     (kargu-bridge--object "scope" scope "call_id" call-id "approved" t))))

(defun kargu-bridge-sensor--reply-tool-result (connection id params outcome text)
  "Reply with Completion struct for ID/PARAMS on CONNECTION."
  (let* ((call-id (gethash "call_id" params))
         (calls (kargu-bridge-connection-sensor-calls connection))
         (call (gethash call-id calls)))
    (when call
      (remhash call-id calls)
      (remhash (concat "sensor:" call-id) (kargu-bridge-connection-reverse-cleanups connection)))
    (kargu-bridge-sensor--reply
     connection id
     (kargu-bridge--object
      "scope" (gethash "scope" params)
      "call_id" call-id
      "quiescent" t
      "outcome" outcome
      "text" (or text "")))))

(defun kargu-bridge-sensor-lsp-call (connection id params)
  "Execute an LSP sensor tool for ID/PARAMS on CONNECTION."
  (let* ((call-id (and (hash-table-p params) (gethash "call_id" params)))
         (calls (kargu-bridge-connection-sensor-calls connection))
         (call (gethash call-id calls))
         (tool (gethash "tool" params))
         (args (gethash "arguments" params)))
    (condition-case nil
        (progn
          (unless (and call (eq (kargu-bridge-sensor-call-state call) :prepared))
            (error "Unowned invocation"))
          (setf (kargu-bridge-sensor-call-state call) :issued
                (kargu-bridge-sensor-call-reverse-id call) id)
          (pcase tool
            ("lsp_diagnostics"
             (require 'kargu/tools/lsp/diagnostics)
             (let* ((path (and (hash-table-p args) (gethash "file_path" args)))
                    (output (if (and (stringp path) (not (string-empty-p (string-trim path))))
                                (kargu-lsp-get-diagnostics path)
                              (kargu-lsp-get-project-diagnostics))))
               (kargu-bridge-sensor--reply-tool-result connection id params "ok" output)))
            ("lsp_find_symbol"
             (require 'kargu/tools/lsp/symbols)
             (let* ((sym (and (hash-table-p args)
                              (or (gethash "symbol_name" args)
                                  (gethash "symbol" args)))))
               (if (and (stringp sym) (not (string-empty-p (string-trim sym))))
                   (kargu-lsp-find-definition
                    sym
                    (lambda (output)
                      (kargu-bridge-sensor--reply-tool-result connection id params "ok" output)))
                 (kargu-bridge-sensor--reply-tool-result connection id params "failed"
                                                         "ERROR: symbol_name is required"))))
            ("lsp_project_skeleton"
             (require 'kargu/tools/lsp/skeleton)
             (kargu-lsp-build-skeleton
              nil
              (lambda (output)
                (kargu-bridge-sensor--reply-tool-result connection id params "ok" output))))
            (_
             (kargu-bridge-sensor--reply-tool-result connection id params "failed"
                                                     (format "ERROR: Unknown sensor tool %s" tool)))))
      ((error quit)
       (kargu-bridge-sensor--reply-tool-result connection id params "failed" "ERROR: Sensor execution failed")))))

(defun kargu-bridge-sensor-call-tool (connection id params)
  "Consume an exact prepared typed read for ID/PARAMS on CONNECTION."
  (let ((tool (and (hash-table-p params) (gethash "tool" params))))
    (cond
     ((member tool '("read_file_symbols" "read_symbol"))
      (require 'kargu/bridge/sensor/symbols)
      (kargu-bridge-sensor-symbols-call connection id params))
     ((member tool '("lsp_diagnostics" "lsp_find_symbol" "lsp_project_skeleton"))
      (kargu-bridge-sensor-lsp-call connection id params))
     (t
      (kargu-bridge-sensor--error connection id)))))

(defun kargu-bridge-sensor-cancel-tool (connection params)
  "Revoke publication for PARAMS while retaining CONNECTION's issued callback."
  (let* ((calls (kargu-bridge-connection-sensor-calls connection))
         (call (and (hash-table-p params) (gethash (gethash "call_id" params) calls))))
    (when (and call (equal (gethash "connection_epoch" params) (kargu-bridge-connection-epoch connection))
               (equal (gethash "request_id" params) (kargu-bridge-sensor-call-reverse-id call))
               (kargu-bridge-session--same-scope-p
                (gethash "scope" params) (gethash "scope" (kargu-bridge-sensor-call-params call)))
               (eq (kargu-bridge-sensor-call-state call) :issued))
      (setf (kargu-bridge-sensor-call-state call) :cancelled))))

(defun kargu-bridge-sensor-resolve-mentions (connection id _params)
  "Refuse ID on CONNECTION until the bounded native context port is connected."
  (kargu-bridge-sensor--error connection id))

(provide 'kargu/bridge/sensor)
;;; sensor.el ends here
