;;; freshness.el --- Diagnostic document and report barriers -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; A Flymake run must report, not merely keep an unchanged snapshot.
;; Eglot can replay cached reports, so its push needs a matching LSP version.

;;; Code:

(require 'cl-lib)
(require 'flymake)
(require 'kargu/tools/lsp/context)

(declare-function eglot--signal-textDocument/didChange "eglot" ())
(declare-function eglot--report-to-flymake "eglot" (diags))
(defvar eglot--versioned-identifier)
(defvar eglot--diagnostics)

(cl-defstruct (kargu-lsp--publication (:constructor kargu-lsp--make-publication))
  "An observed Eglot publication tied to its server and document."
  server version tick)

(defvar-local kargu-lsp--publication nil
  "Last Eglot publication observed in this buffer.")

(cl-defstruct (kargu-lsp--backend-report (:constructor kargu-lsp--make-backend-report))
  "One Flymake report function's document version and publication status."
  tick reported)

(defvar-local kargu-lsp--backend-reports nil
  "Map Flymake backend identities to their latest report-function generation.")

(defun kargu-lsp--track-report-function (make-report backend &optional token)
  "Wrap MAKE-REPORT for BACKEND and TOKEN with document-generation evidence."
  (unless kargu-lsp--backend-reports
    (setq kargu-lsp--backend-reports (make-hash-table :test #'eq)))
  (let ((report (funcall make-report backend token))
        (buffer (current-buffer))
        (entry (kargu-lsp--make-backend-report :tick (buffer-chars-modified-tick))))
    (puthash backend entry kargu-lsp--backend-reports)
    (lambda (&rest args)
      (save-match-data
        (prog1 (apply report args)
          (when (and (buffer-live-p buffer)
                     (fboundp 'kargu-lsp--backend-report-tick))
            (with-current-buffer buffer
              (let ((current (and kargu-lsp--backend-reports
                                  (gethash backend kargu-lsp--backend-reports))))
                (cond
                 ((and (eq entry current)
                       (= (kargu-lsp--backend-report-tick entry) (buffer-chars-modified-tick))
                       (listp (car args)))
                  (setf (kargu-lsp--backend-report-reported entry) t))
                 ((and current (plist-get (cdr args) :force))
                  (setf (kargu-lsp--backend-report-reported current) nil)))))))))))

(advice-add 'flymake-make-report-fn :around #'kargu-lsp--track-report-function)

(cl-defstruct (kargu-lsp-diagnostic-barrier
               (:constructor kargu-lsp--make-diagnostic-barrier))
  "Captured document and checker identities for one verification."
  buffer file tick server version backends reports)

(defun kargu-lsp--forget-publication ()
  "Invalidate cached publications on Eglot management transitions."
  (setq kargu-lsp--publication nil))

(defun kargu-lsp--observe-publication (server uri version)
  "Record SERVER's publication for URI, including optional VERSION."
  (when-let* ((buffer (find-buffer-visiting (eglot-uri-to-path uri))))
    (with-current-buffer buffer
      (when (eq server (eglot-current-server))
        (setq kargu-lsp--publication
              (kargu-lsp--make-publication
               :server server :version version :tick (buffer-chars-modified-tick)))))))

(defun kargu-lsp--diagnostic-capabilities (capabilities)
  "Add version support to a private copy of Eglot CAPABILITIES."
  (let* ((copy (copy-tree capabilities t))
         (document (plist-get copy :textDocument))
         (diagnostics (plist-get document :publishDiagnostics)))
    (plist-put copy :textDocument
               (plist-put document :publishDiagnostics
                          (plist-put diagnostics :versionSupport t)))))

(defun kargu-lsp--observe-notification (handle server method &rest params)
  "Call HANDLE for SERVER, METHOD and PARAMS, then observe diagnostics."
  (save-match-data
    (prog1 (apply handle server method params)
      (when (eq method 'textDocument/publishDiagnostics)
        (kargu-lsp--observe-publication
         server (plist-get params :uri) (plist-get params :version))))))

(with-eval-after-load 'eglot
  (advice-add 'eglot-client-capabilities :filter-return #'kargu-lsp--diagnostic-capabilities)
  (advice-add 'eglot-handle-notification :around #'kargu-lsp--observe-notification)
  (add-hook 'eglot-managed-mode-hook #'kargu-lsp--forget-publication))

(defun kargu/tools/lsp/freshness-unload-function ()
  "Detach external observers before unloading this feature."
  (advice-remove 'flymake-make-report-fn #'kargu-lsp--track-report-function)
  (advice-remove 'eglot-client-capabilities #'kargu-lsp--diagnostic-capabilities)
  (advice-remove 'eglot-handle-notification #'kargu-lsp--observe-notification)
  (remove-hook 'eglot-managed-mode-hook #'kargu-lsp--forget-publication)
  nil)

(defun kargu-lsp--diagnostic-backends ()
  "Return the effective Flymake backend functions in this buffer."
  (let (backends)
    (run-hook-wrapped 'flymake-diagnostic-functions
                      (lambda (backend) (push backend backends) nil))
    (nreverse backends)))

(defun kargu-lsp--diagnostic-backends-match-p (expected)
  "Return non-nil when current backend identities match EXPECTED."
  (let ((actual (kargu-lsp--diagnostic-backends)))
    (and (= (length actual) (length expected))
         (cl-every #'eq actual expected))))

(defun kargu-lsp--start-buffer-diagnostic-barrier ()
  "Capture this buffer's version and start its configured backend generation."
  (let* ((server (and (bound-and-true-p eglot--managed-mode) (eglot-current-server)))
         (backends (kargu-lsp--diagnostic-backends)))
    (when server (eglot--signal-textDocument/didChange))
    (let ((barrier
           (kargu-lsp--make-diagnostic-barrier
            :buffer (current-buffer) :file buffer-file-name
            :tick (buffer-chars-modified-tick) :server server
            :version (and server eglot--versioned-identifier) :backends backends)))
      (when backends
        (flymake-start)
        (setf (kargu-lsp-diagnostic-barrier-reports barrier)
              (mapcar (lambda (backend)
                        (and kargu-lsp--backend-reports
                             (gethash backend kargu-lsp--backend-reports)))
                      backends))
        barrier))))

(defun kargu-lsp-begin-diagnostic-barrier (buffer)
  "Capture a new diagnostic barrier for BUFFER, or return nil.
Restart configured Flymake backends without waiting for their reports.
An Eglot document is flushed asynchronously before capturing its version.
No file is opened, checker enabled or disabled backend forced."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (save-excursion
        (save-restriction
          (widen)
          (when (and flymake-mode buffer-file-name)
            (kargu-lsp--start-buffer-diagnostic-barrier)))))))

(defun kargu-lsp-diagnostic-barrier-valid-p (barrier)
  "Return non-nil while BARRIER still identifies the same checked document."
  (when-let* ((buffer (kargu-lsp-diagnostic-barrier-buffer barrier))
              ((buffer-live-p buffer)))
    (with-current-buffer buffer
      (and flymake-mode
           (equal buffer-file-name (kargu-lsp-diagnostic-barrier-file barrier))
           (= (buffer-chars-modified-tick) (kargu-lsp-diagnostic-barrier-tick barrier))
           (eq (and (bound-and-true-p eglot--managed-mode) (eglot-current-server))
               (kargu-lsp-diagnostic-barrier-server barrier))
           (kargu-lsp--diagnostic-backends-match-p
            (kargu-lsp-diagnostic-barrier-backends barrier))
           (cl-every (lambda (backend report)
                       (and report kargu-lsp--backend-reports
                            (eq report (gethash backend kargu-lsp--backend-reports))))
                     (kargu-lsp-diagnostic-barrier-backends barrier)
                     (kargu-lsp-diagnostic-barrier-reports barrier))
           (not (seq-intersection (kargu-lsp-diagnostic-barrier-backends barrier)
                                  (flymake-disabled-backends) #'eq))))))

(defun kargu-lsp--publication-matches-p (barrier)
  "Return non-nil when the current Eglot publication matches BARRIER."
  (let ((report kargu-lsp--publication))
    (and report (integerp (kargu-lsp--publication-version report))
         (eq (kargu-lsp--publication-server report)
             (kargu-lsp-diagnostic-barrier-server barrier))
         (equal (kargu-lsp--publication-version report)
                (kargu-lsp-diagnostic-barrier-version barrier))
         (= (kargu-lsp--publication-tick report)
            (kargu-lsp-diagnostic-barrier-tick barrier)))))

(defun kargu-lsp-diagnostic-barrier-ready-p (barrier)
  "Return non-nil after every backend in BARRIER has reported fresh data."
  (and (kargu-lsp-diagnostic-barrier-valid-p barrier)
       (with-current-buffer (kargu-lsp-diagnostic-barrier-buffer barrier)
         (and (seq-every-p #'kargu-lsp--backend-report-reported
                           (kargu-lsp-diagnostic-barrier-reports barrier))
              (or (not (kargu-lsp-diagnostic-barrier-server barrier))
                  (kargu-lsp--publication-matches-p barrier))))))

(defun kargu-lsp-sync-diagnostic-barrier (barrier)
  "Publish BARRIER's verified Eglot cache to Flymake, returning readiness.
Eglot may otherwise defer that cache in manual Flymake mode.  No server
request is sent and no new backend generation is started."
  (when (kargu-lsp-diagnostic-barrier-ready-p barrier)
    (with-current-buffer (kargu-lsp-diagnostic-barrier-buffer barrier)
      (save-excursion
        (when (kargu-lsp-diagnostic-barrier-server barrier)
          (eglot--report-to-flymake eglot--diagnostics))))
    (kargu-lsp-diagnostic-barrier-ready-p barrier)))

(provide 'kargu/tools/lsp/freshness)
;;; freshness.el ends here
