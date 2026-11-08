;;; symbols.el --- Scoped typed symbol observations for native tools -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Supply raw symbols or the exact range selected by Rust.  An issued callback
;; stays owned until its actual return even after Stop or source retirement.

;;; Code:

(require 'kargu/bridge/sensor)
(require 'kargu/tools/lsp/snapshot nil t)

(defvar kargu-lsp-snapshot--items 64
  "Fallback symbol budget; `kargu/tools/lsp/snapshot' replaces it when loaded.")
(defvar kargu-lsp-snapshot--bytes 16384
  "Fallback symbol byte budget; `kargu/tools/lsp/snapshot' replaces it when loaded.")
(declare-function kargu-lsp-snapshot-limit "kargu/tools/lsp/snapshot" (symbols maximum))
(declare-function kargu-lsp-snapshot-capture "kargu/tools/lsp/snapshot"
                  (buffer source callback timeout-ms))
(declare-function kargu-lsp-snapshot-body "kargu/tools/lsp/snapshot" (range))

(defun kargu-bridge-sensor-symbols--size (value)
  "Return exact UTF-8 JSON framing bytes for detached VALUE."
  (string-bytes (json-serialize value :false-object :json-false :null-object :json-null)))

(defun kargu-bridge-sensor-symbols--fit (connection id result)
  "Fit typed RESULT for ID within CONNECTION's negotiated frame and sensor limits."
  (let* ((observation (gethash "observation" result))
         (snapshot (and (hash-table-p observation) (gethash "snapshot" observation)))
         (kind (and (hash-table-p observation) (gethash "kind" observation)))
         (remaining kargu-lsp-snapshot--items)
         (envelope (kargu-bridge--object "jsonrpc" "2.0" "id" id "result" result))
         (limit (kargu-bridge-connection-frame-limit connection)))
    (while (and snapshot
                (or (> (kargu-bridge-sensor-symbols--size envelope) limit)
                    (and (equal kind "symbols")
                         (> (kargu-bridge-sensor-symbols--size (gethash "symbols" snapshot))
                            kargu-lsp-snapshot--bytes))))
      (cond
       ((and (equal kind "symbols") (> remaining 0))
        (setq remaining (/ remaining 2))
        (puthash "symbols" (kargu-lsp-snapshot-limit (gethash "symbols" snapshot) remaining) snapshot))
       ((and (equal kind "body") (> (length (gethash "text" snapshot)) 0))
        (puthash "text" (substring (gethash "text" snapshot) 0 (/ (length (gethash "text" snapshot)) 2)) snapshot)
        (puthash "truncated" t snapshot))
       ((and (equal kind "project_diagnostics")
             (or (> (length (gethash "live" snapshot)) 0) (> (length (gethash "cached" snapshot)) 0)))
        (dolist (key '("live" "cached"))
          (let ((rows (gethash key snapshot)))
            (puthash key (vconcat (seq-take rows (/ (length rows) 2))) snapshot)))
        (puthash "truncated" t snapshot))
       (t
        ;; Metadata itself cannot fit.  A compact negative result still reports
        ;; actual quiescence and never switches to the old formatter or disk.
        (puthash "observation" (kargu-bridge--object "kind" "unavailable" "reason" "resource_limit") result)
        (puthash "outcome" "failed" result)
        (setq snapshot nil))))
    result))

(defun kargu-bridge-sensor-symbols--forget (connection call)
  "Release CALL's pure observation from CONNECTION after callback or capture."
  (let ((call-id (gethash "call_id" (kargu-bridge-sensor-call-params call))))
    (remhash call-id (kargu-bridge-connection-sensor-calls connection))
    (remhash (concat "sensor:" call-id) (kargu-bridge-connection-reverse-cleanups connection))))

(defun kargu-bridge-sensor-symbols--finish (connection call id outcome &optional observation next)
  "Finish CALL's reverse ID on CONNECTION with OUTCOME/OBSERVATION.
Optionally retain NEXT."
  (when (memq (kargu-bridge-sensor-call-state call) '(:issued :cancelled))
    (when (eq (kargu-bridge-sensor-call-state call) :cancelled)
      (setq outcome "cancelled" observation nil next nil))
    (let* ((params (kargu-bridge-sensor-call-params call))
           (result (kargu-bridge--object "scope" (gethash "scope" params)
                                         "call_id" (gethash "call_id" params)
                                         "quiescent" t "outcome" outcome)))
      (when observation (puthash "observation" observation result))
      (kargu-bridge-sensor-symbols--fit connection id result)
      (if (and next (equal (gethash "outcome" result) "ok"))
          (setf (kargu-bridge-sensor-call-state call) next)
        (setf (kargu-bridge-sensor-call-state call) :settled)
        (kargu-bridge-sensor-symbols--forget connection call))
      (kargu-bridge-sensor--reply connection id result))))

(defun kargu-bridge-sensor-symbols--refuse (connection id params)
  "Refuse an unentered ID/PARAMS on CONNECTION without consuming observation."
  (kargu-bridge-sensor--reply
   connection id (kargu-bridge--object "scope" (gethash "scope" params)
                                      "call_id" (gethash "call_id" params) "quiescent" t "outcome" "rejected"
                                      "observation" (kargu-bridge--object "kind" "unavailable" "reason" "stale"))))

(defun kargu-bridge-sensor-symbols--failed (connection call id reason)
  "Settle CALL's ID with closed native failure REASON on CONNECTION."
  (let ((reason (if (memq reason '(stale unavailable invalid_range timeout cancelled resource_limit)) reason 'unavailable)))
    (kargu-bridge-sensor-symbols--finish
     connection call id (pcase reason ('timeout "timeout") ('cancelled "cancelled") (_ "failed"))
     (kargu-bridge--object "kind" "unavailable" "reason" (symbol-name reason)))))

(defun kargu-bridge-sensor-symbols-call (connection id params)
  "Enter ID/PARAMS once on CONNECTION and return raw provider-bound symbols."
  (let* ((call-id (and (hash-table-p params) (gethash "call_id" params)))
         (call (gethash call-id (kargu-bridge-connection-sensor-calls connection))) entered)
    (condition-case nil
        (progn
          (unless (and call (eq (kargu-bridge-sensor-call-state call) :prepared)
                       (kargu-bridge-sensor--live-p connection call params)
                       (kargu-bridge-sensor--equal-p (gethash "resource" params) (kargu-bridge-sensor-call-resource call)))
            (error "Unowned invocation"))
          (setf (kargu-bridge-sensor-call-state call) :issued
                (kargu-bridge-sensor-call-reverse-id call) id)
          (setq entered t)
          (let* ((resource (kargu-bridge-sensor-call-resource call))
                 (buffer (kargu-bridge-sensor-call-buffer call))
                 (root (gethash "root" (kargu-bridge-sensor-call-params call))))
            (kargu-lsp-snapshot-capture
             buffer (gethash "source" resource)
             (lambda (symbols failure)
               (condition-case nil
                   (if (or failure (not (kargu-bridge-sensor--live-p connection call params)))
                       (kargu-bridge-sensor-symbols--failed connection call id (if failure failure 'stale))
                     (let ((observed (kargu-bridge-sensor--language-document buffer root)))
                       (kargu-bridge-sensor-symbols--finish
                        connection call id "ok"
                        (kargu-bridge--object
                         "kind" "symbols" "snapshot"
                         (kargu-bridge--object
                          "requested" (gethash "document" resource) "observed" (gethash "document" observed)
                          "source" (gethash "source" resource) "observed_source" (gethash "source" observed)
                          "symbols" symbols))
                        (when (equal (gethash "tool" params) "read_symbol") :symbols-ready))))
                 (quit (kargu-bridge-sensor-symbols--failed connection call id 'cancelled))
                 (error (kargu-bridge-sensor-symbols--failed connection call id 'stale))))
             (gethash "timeout_ms" params))))
      ((error quit)
       (if entered (kargu-bridge-sensor-symbols--failed connection call id 'unavailable)
         (when (and call (eq (kargu-bridge-sensor-call-state call) :prepared)
                    (kargu-bridge-sensor--same-call-p connection call params))
           (kargu-bridge-sensor-symbols--forget connection call))
         (kargu-bridge-sensor-symbols--refuse connection id params))))))

(defun kargu-bridge-sensor-symbols-body (connection id params)
  "Capture the exact native-selected scalar range in ID/PARAMS on CONNECTION."
  (let* ((call-id (and (hash-table-p params) (gethash "call_id" params)))
         (call (gethash call-id (kargu-bridge-connection-sensor-calls connection))) entered)
    (condition-case nil
        (progn
          (unless (and call (eq (kargu-bridge-sensor-call-state call) :symbols-ready)
                       (equal (gethash "tool" params) "read_symbol")
                       (kargu-bridge-sensor--live-p connection call params)
                       (kargu-bridge-sensor--equal-p (gethash "resource" params) (kargu-bridge-sensor-call-resource call)))
            (error "Unowned symbol range"))
          (setf (kargu-bridge-sensor-call-state call) :issued
                (kargu-bridge-sensor-call-reverse-id call) id)
          (setq entered t)
          (with-current-buffer (kargu-bridge-sensor-call-buffer call)
            (let* ((body (kargu-lsp-snapshot-body (gethash "range" params)))
                   (root (gethash "root" (kargu-bridge-sensor-call-params call)))
                   (resource (kargu-bridge-sensor--language-document (current-buffer) root)))
              (unless (kargu-bridge-sensor--live-p connection call params) (error "Symbol source changed"))
              (puthash "document" (gethash "document" resource) body)
              (puthash "source" (gethash "source" resource) body)
              (kargu-bridge-sensor-symbols--finish
               connection call id "ok" (kargu-bridge--object "kind" "body" "snapshot" body)))))
      ((error quit)
       (if entered (kargu-bridge-sensor-symbols--failed connection call id 'invalid_range)
         (when (and call (eq (kargu-bridge-sensor-call-state call) :symbols-ready)
                    (kargu-bridge-sensor--same-call-p connection call params))
           (kargu-bridge-sensor-symbols--forget connection call))
         (kargu-bridge-sensor-symbols--refuse connection id params))))))

(defun kargu-bridge-sensor-symbols-release (connection params)
  "Release only PARAMS' exact quiescent symbol observation on CONNECTION."
  (let* ((call-id (and (hash-table-p params) (gethash "call_id" params)))
         (call (gethash call-id (kargu-bridge-connection-sensor-calls connection)))
         (original (and call (kargu-bridge-sensor-call-params call))))
    (when (and call (memq (kargu-bridge-sensor-call-state call) '(:prepared :symbols-ready))
               (eq (kargu-bridge-session-owned-entry connection params) (kargu-bridge-sensor-call-entry call))
               (cl-every (lambda (key) (kargu-bridge-sensor--equal-p (gethash key params) (gethash key original)))
                         '("request_id" "connection_epoch" "scope" "call_id")))
      (setf (kargu-bridge-sensor-call-state call) :settled)
      (kargu-bridge-sensor-symbols--forget connection call))))

(provide 'kargu/bridge/sensor/symbols)
;;; symbols.el ends here
