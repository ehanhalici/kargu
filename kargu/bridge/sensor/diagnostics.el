;;; diagnostics.el --- Raw live diagnostic observations -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Observe Emacs objects only.  Rust evaluates freshness and renders findings.
;; Existing bounded reverse-read completion retains scope and actual quiescence.

;;; Code:

(require 'kargu/bridge/sensor/symbols)
(require 'kargu/tools/lsp/freshness)
(require 'kargu/tools/lsp/coordinates)

(defvar kargu-bridge-diagnostics--identities (make-hash-table :test #'eq :weakness 'key)
  "Opaque identities for actual editor objects, never printed closures.")
(defvar kargu-bridge-diagnostics--generations (make-hash-table :test #'eq :weakness 'key)
  "Report-function objects and their transport generation handles.")
(defvar kargu-bridge-diagnostics--sequence 1
  "Next report-function transport generation handle.")

(defun kargu-bridge-diagnostics--identity (object)
  "Return a transport identity for live editor OBJECT."
  (or (gethash object kargu-bridge-diagnostics--identities)
      (puthash object (concat "diagnostic_source_" (kargu-random-uuid))
               kargu-bridge-diagnostics--identities)))

(defun kargu-bridge-diagnostics--generation (report)
  "Return the transport generation for actual REPORT, or an unreported slot."
  (if (null report) 1
    (or (gethash report kargu-bridge-diagnostics--generations)
        (puthash report (cl-incf kargu-bridge-diagnostics--sequence)
                 kargu-bridge-diagnostics--generations))))

(defun kargu-bridge-diagnostics--server ()
  "Capture raw Eglot process/publication facts, or nil without a server."
  (when-let* ((server (and (bound-and-true-p eglot--managed-mode) (eglot-current-server))))
    (let* ((process (ignore-errors (jsonrpc--process server)))
           (publication kargu-lsp--publication)
           (observed (and publication (kargu-lsp--publication-process publication))))
      (kargu-bridge--object
       "requested_server" (if (and (processp process) (process-live-p process)) (kargu-bridge-diagnostics--identity process) "unavailable-process")
       "observed_server" (if (and publication (eq server (kargu-lsp--publication-server publication))
                                   (processp observed))
                              (kargu-bridge-diagnostics--identity observed) "unobserved-process")
       "requested_version" (if (integerp eglot--versioned-identifier) eglot--versioned-identifier :json-null)
       "published_version" (if (and publication (integerp (kargu-lsp--publication-version publication)))
                               (kargu-lsp--publication-version publication) :json-null)
       "tick" (if publication (kargu-lsp--publication-tick publication) (buffer-chars-modified-tick))))))

(defun kargu-bridge-diagnostics--producer (backend)
  "Return the transport source identity for actual Flymake BACKEND."
  (unless backend (error "Missing diagnostic producer"))
  (if (symbolp backend) (symbol-name backend) (kargu-bridge-diagnostics--identity backend)))

(defun kargu-bridge-diagnostics--facts (diagnostic)
  "Capture DIAGNOSTIC's editor fields, returning (FACTS . TRUNCATED)."
  (let* ((message (flymake-diagnostic-text diagnostic))
         (cut (> (length message) 4096))
         (backend (flymake-diagnostic-backend diagnostic))
         (severity (pcase (kargu-lsp--diagnostic-severity (flymake-diagnostic-type diagnostic))
                     (1 "error") (2 "warning") (_ "info"))))
    (cons (kargu-bridge--object
           "source" (kargu-bridge-diagnostics--producer backend)
           "code" :json-null "severity" severity
           "message" (substring-no-properties message 0 (min 4096 (length message)))) cut)))

(defun kargu-bridge-diagnostics--finding (diagnostic)
  "Capture raw Flymake DIAGNOSTIC in the current source buffer."
  (let ((capture (kargu-bridge-diagnostics--facts diagnostic)))
    (puthash "range" (kargu-lsp-coordinate-range (flymake-diagnostic-beg diagnostic)
                                               (flymake-diagnostic-end diagnostic)) (car capture))
    capture))

(defun kargu-bridge-diagnostics--snapshot (buffer root requested)
  "Capture BUFFER's raw facts under ROOT for REQUESTED document stamp."
  (with-current-buffer buffer
    (save-excursion
      (save-restriction
        (widen)
        (let ((backends (and flymake-mode (kargu-lsp--diagnostic-backends))) reports findings truncated)
          (when (> (length backends) 64) (setq backends (seq-take backends 64) truncated t))
          (dolist (backend backends)
            (let* ((report (and kargu-lsp--backend-reports (gethash backend kargu-lsp--backend-reports)))
                   (generation (kargu-bridge-diagnostics--generation report)))
              (push (kargu-bridge--object
                     "backend" (kargu-bridge-diagnostics--producer backend)
                     "requested" generation "observed" generation
                     "tick" (if report (kargu-lsp--backend-report-tick report) (buffer-chars-modified-tick))
                     "reported" (if (and report (kargu-lsp--backend-report-reported report)) t :json-false)) reports)))
          (let ((count 0) (bytes 0) (work 0))
            (catch 'bounded
              (dolist (finding (when flymake-mode (flymake-diagnostics)))
                (when (>= count 4096) (setq truncated t) (throw 'bounded nil))
                (cl-incf count)
                (setq work (+ work (- (flymake-diagnostic-beg finding) (point-min))
                              (- (flymake-diagnostic-end finding) (point-min))))
                (when (> work (* 8 1024 1024)) (setq truncated t) (throw 'bounded nil))
                (let* ((captured (kargu-bridge-diagnostics--finding finding))
                       (record (car captured)))
                  (when (cdr captured) (setq truncated t))
                  (setq bytes (+ bytes (kargu-bridge-sensor-symbols--size record)))
                  (when (> bytes (* 128 1024)) (setq truncated t) (throw 'bounded nil))
                  (push record findings)))))
          (kargu-bridge--object
           "requested" requested "observed" (gethash "document" (kargu-bridge-sensor--document buffer root))
           "available" (if (and flymake-mode backends
                                (not (seq-intersection backends (flymake-disabled-backends) #'eq))) t :json-false)
           "backends" (vconcat (nreverse reports)) "server" (or (kargu-bridge-diagnostics--server) :json-null)
           "diagnostics" (vconcat (nreverse findings)) "truncated" (if truncated t :json-false)))))))

(defun kargu-bridge-diagnostics--owned-path (path root)
  "Return canonical local PATH inside captured ROOT, before inspecting findings."
  (when (and (stringp path) (file-name-absolute-p path) (not (file-remote-p path))
             (string-prefix-p (file-name-as-directory root) (expand-file-name path))
             (file-in-directory-p path root))
    (file-truename path)))

(defun kargu-bridge-diagnostics--cached (diagnostic root)
  "Capture unversioned file-locus DIAGNOSTIC under ROOT, or nil when foreign."
  (when-let* ((path (kargu-bridge-diagnostics--owned-path (flymake--diag-locus diagnostic) root)))
    (let* ((position (flymake-diagnostic-beg diagnostic))
           (line (car-safe position)) (column (cdr-safe position)))
      (unless (and (integerp line) (<= 1 line #x7fffffffffffffff)
                   (or (null column) (and (integerp column) (<= 0 column #x8000000000000000))))
        (error "Unsupported cached diagnostic position"))
      (let ((capture (kargu-bridge-diagnostics--facts diagnostic)))
        (puthash "path" (file-relative-name path root) (car capture))
        (puthash "line" line (car capture))
        (puthash "column" (if (and column (> column 0)) (1- column) :json-null) (car capture))
        capture))))

(defun kargu-bridge-diagnostics--project (root)
  "Observe live documents and raw Flymake file-cache entries under ROOT.
Rust owns grouping, deduplication, supersession and rendering."
  (let ((bytes 0) (files 0) (items 0) live cached truncated)
    (cl-labels
        ((reserve (value)
           (setq bytes (+ bytes (kargu-bridge-sensor-symbols--size value)))
           (when (> bytes (* 128 1024)) (setq truncated t) (throw 'bounded nil)))
         (cache (diagnostic)
           (when (> (cl-incf items) 4096) (setq truncated t) (throw 'bounded nil))
           (condition-case nil
               (when-let* ((capture (kargu-bridge-diagnostics--cached diagnostic root)))
                 (when (cdr capture) (setq truncated t))
                 (reserve (car capture))
                 (push (car capture) cached))
             (error (setq truncated t)))))
      (catch 'bounded
        (dolist (buffer (buffer-list))
          (when (and (not (buffer-base-buffer buffer))
                     (kargu-bridge-diagnostics--owned-path (buffer-file-name buffer) root))
            (when (> (cl-incf files) 256) (setq truncated t) (throw 'bounded nil))
            (condition-case nil
                (let* ((document (gethash "document" (kargu-bridge-sensor--document buffer root)))
                       (snapshot (kargu-bridge-diagnostics--snapshot buffer root document)))
                  (reserve snapshot)
                  (push snapshot live))
              (error (setq truncated t)))
            (with-current-buffer buffer
              (when (hash-table-p flymake--state)
                (maphash (lambda (_backend state)
                           (when-let* ((foreign (flymake--state-foreign-diags state)))
                             (maphash (lambda (_path findings) (mapc #'cache findings)) foreign)))
                         flymake--state)))))
        (dolist (entry flymake-list-only-diagnostics)
          (mapc #'cache (cdr entry)))))
    (kargu-bridge--object "live" (vconcat (nreverse live)) "cached" (vconcat (nreverse cached))
                         "truncated" (if truncated t :json-false))))

(defun kargu-bridge-sensor-diagnostics-call (connection id params)
  "Return raw diagnostic facts for captured ID/PARAMS on CONNECTION."
  (let* ((call-id (and (hash-table-p params) (gethash "call_id" params)))
         (call (gethash call-id (kargu-bridge-connection-sensor-calls connection))) entered)
    (condition-case nil
        (progn
          (unless (and call (eq (kargu-bridge-sensor-call-state call) :prepared)
                       (kargu-bridge-sensor--same-call-p connection call params)
                       (kargu-bridge-sensor--equal-p (gethash "resource" params)
                                                   (kargu-bridge-sensor-call-resource call)))
            (error "Unowned diagnostic invocation"))
          (setq entered t)
          (setf (kargu-bridge-sensor-call-state call) :issued
                (kargu-bridge-sensor-call-reverse-id call) id)
          (let* ((resource (kargu-bridge-sensor-call-resource call))
                 (root (gethash "root" params))
                 (buffer (kargu-bridge-sensor-call-buffer call)))
            (let ((observation
                   (pcase (gethash "kind" resource)
                     ("document"
                      (unless (and (buffer-live-p buffer)
                                   (kargu-bridge-sensor--equal-p resource (kargu-bridge-sensor--document buffer root)))
                        (error "Diagnostic document unavailable"))
                      (kargu-bridge--object "kind" "diagnostics" "snapshot"
                                            (kargu-bridge-diagnostics--snapshot buffer root (gethash "document" resource))))
                     ("workspace"
                      (let ((path (gethash "file_path" (gethash "arguments" params))))
                        (when (and (stringp path) (not (string-empty-p path)))
                          (error "File-specific diagnostics cannot acquire project scope")))
                      (kargu-bridge--object "kind" "project_diagnostics" "snapshot"
                                            (kargu-bridge-diagnostics--project root)))
                     (_ (error "Unsupported diagnostic resource")))))
              (unless (kargu-bridge-sensor--same-call-p connection call params) (error "Retired diagnostic source"))
              (kargu-bridge-sensor-symbols--finish connection call id "ok" observation))))
      (quit
       (if entered (kargu-bridge-sensor-symbols--failed connection call id 'cancelled)
         (kargu-bridge-sensor-symbols--refuse connection id params)))
      (error
       (if entered (kargu-bridge-sensor-symbols--failed connection call id 'unavailable)
         (kargu-bridge-sensor-symbols--refuse connection id params))))))

(provide 'kargu/bridge/sensor/diagnostics)
;;; diagnostics.el ends here
