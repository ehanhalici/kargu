;;; schema.el --- Configuration cache and setup verification -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Configuration file cache, setup check verification, and provider switching.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'kargu/core)
(require 'kargu/state)
(require 'kargu/config/key)
(require 'kargu/config/service)
(require 'kargu/models/service)

(autoload 'kargu-check-setup "kargu/config/setup" nil t)

(defun kargu-config-revision ()
  "Return current monotonic integer revision of the configuration."
  (kargu-config-service-revision (kargu-config-service-context)))

(defun kargu--xdg-config-file ()
  "Return `$XDG_CONFIG_HOME/kargu/config.toml' (default ~/.config/...)."
  (expand-file-name
   "kargu/config.toml"
   (or (and (stringp (getenv "XDG_CONFIG_HOME"))
            (not (string-empty-p (getenv "XDG_CONFIG_HOME")))
            (getenv "XDG_CONFIG_HOME"))
       (expand-file-name ".config" (or (getenv "HOME") "~")))))

(defun kargu-config-file ()
  "Return the published TOML path, or the default XDG candidate, without I/O."
  (or (when-let* ((snapshot (kargu-config-service-snapshot (kargu-config-service-context))))
        (kargu-config-snapshot-path snapshot))
      (kargu--xdg-config-file)))

(defun kargu--config-plist ()
  "Return borrowed read-only configuration data without filesystem access."
  (kargu-config-current-data))

(defun kargu--config-providers ()
  "Alist of (NAME . PLIST) for `[providers.*]' tables."
  (plist-get (kargu--config-plist) :providers))

(defun kargu-set-provider (name &optional no-model callback)
  "Select NAME asynchronously using native default-model policy.
NO-MODEL requests an empty model choice.  Return a cancellable task; optional
CALLBACK receives a Result after the UI has adopted the native choice."
  (interactive
   (let ((choices (delete-dups (append (mapcar #'car (kargu--config-providers)) (kargu-provider-list)))))
     (unless choices (user-error "Kargu: no providers available"))
     (list (completing-read "kargu provider: " choices nil t nil nil (kargu--provider-name)))))
  (kargu-selection-require-idle)
  (let* ((name (downcase (string-trim (if (symbolp name) (symbol-name name) name))))
         (origin (current-buffer)) (app (kargu-application-context))
         (mode major-mode)
         (session (kargu-session-context)) (before (kargu-selection-context))
         (cached (kargu-config-copy (gethash name (kargu-metadata-table :catalog kargu--live-models-cache))))
         committed task)
    (cl-labels
        ((valid ()
           (and (buffer-live-p origin) (eq session (kargu-session-context origin))
                (with-current-buffer origin (eq major-mode mode))
                (eq (or committed before) (kargu-selection-context session))
                (not (kargu-selection-busy-p))))
         (selected (value failure)
           (if failure (kargu-async-finish task (kargu-err "Native provider selection unavailable" :config-unavailable))
             (let ((model (gethash "model" value)))
               (unless (and (equal name (gethash "provider" value))
                            (or (stringp model) (eq model :json-null)))
                 (error "Invalid native provider selection"))
               (setq committed (kargu-selection-update :provider (gethash "provider" value)
                                                       :model (unless (eq model :json-null) model) :effort nil))
               (if (not committed) (kargu-async-finish task (kargu-err "Provider selection was superseded" :stale))
                 (when (fboundp 'kargu-api-prefetch-models) (kargu-api-prefetch-models name))
                 (kargu-log 'info "provider set to %s (model %s)" name (or (kargu-selection-model-value committed) "none"))
                 (message "kargu provider: %s (model %s)" name (or (kargu-selection-model-value committed) "none"))
                 (kargu-async-finish task (kargu-ok committed))))))
         (ready (result)
           (if (kargu-err-p result) (kargu-async-finish task result)
             (kargu-bridge-config-query
              "configuration/select"
              (kargu-bridge--object "revision" (kargu-config-revision) "provider" name
                                    "no_model" (if no-model t :json-false) "batch" (if noninteractive t :json-false)
                                    "cached_models" (vconcat cached))
              (kargu-async-wrap task #'selected) :parent task :application app))))
      (setq task (kargu-async-start
                  (kargu-application-wrap app (lambda (value failure)
                                                (let ((result (or value (kargu-err failure :selection-failed))))
                                                  (if callback (funcall callback result)
                                                    (when (kargu-err-p result) (message "Kargu: provider selection failed"))))))
                  :valid-p (kargu-application-wrap app #'valid) :owner nil :parent nil :buffer origin :timeout 5))
      (let ((cancel (lambda () (kargu-async-cancel task))))
        (add-hook 'kill-buffer-hook cancel nil t)
        (add-hook 'change-major-mode-hook cancel nil t)
        (kargu-async-add-cleanup
         task (lambda () (when (buffer-live-p origin)
                           (with-current-buffer origin
                             (remove-hook 'kill-buffer-hook cancel t)
                             (remove-hook 'change-major-mode-hook cancel t))))))
      (kargu-config-ensure-native-async (kargu-async-wrap task #'ready) :parent task))
    task))

(defun kargu--example-config-path ()
  "Path of the shipped config.toml.example, or nil."
  (when-let* ((lib (locate-library "kargu")))
    (expand-file-name "config.toml.example"
                      (file-name-directory lib))))

(defun kargu-edit-config ()
  "Open the local TOML config, creating it from the example if needed."
  (interactive)
  (let* ((path (kargu-config-file))
         (dir (file-name-directory path)))
    (unless (file-exists-p path)
      (when dir (make-directory dir t))
      (let ((example (kargu--example-config-path)))
        (if (and example (file-readable-p example))
            (copy-file example path)
          (with-temp-file path
            (insert "# Local kargu credentials — do not commit.\n"
                    "provider = \"local\"\n"
                    "model = \"\"\n\n"
                    "[providers.local]\n"
                    "api = \"http://127.0.0.1:1/v1\"\n"
                    "apikey = \"...\"\n"
                    "models = []\n"))))
      (kargu-log 'info "created config %s" path)
      (message "kargu: created %s — fill in apikey" path))
    (find-file path)))

(defconst kargu--dependencies
  '((transient . "menu interface (mandatory)")
    (magit . "Git interface (mandatory)")
    (ediff . "diff approval engine (built into Emacs)"))
  "Feature -> purpose map checked by `kargu-check-setup'.")

(defun kargu--missing-dependencies ()
  "Return a list of (FEATURE . PURPOSE) for missing packages."
  (cl-remove-if (lambda (dep)
                  (let ((feat (car dep)))
                    (cond
                     ((eq feat 'eglot)
                      (or (featurep 'eglot)
                          (locate-library "eglot")))
                     (t
                      (or (featurep feat)
                          (locate-library (symbol-name feat)))))))
                kargu--dependencies))

(defun kargu--setup-problems (key missing-tools missing-packages)
  "Return problems and warnings for KEY, MISSING-TOOLS and MISSING-PACKAGES."
  (let (problems warnings)
    (cond
     ((null key)
      (push (format "no API key (M-x kargu-edit-config → %s)"
                    (kargu-config-file))
            problems))
     ((kargu--api-key-placeholder-p key)
      (push (if (string-empty-p key)
                "API key is empty; requests will omit Authorization"
              "API key looks like a placeholder")
            warnings)))
    (dolist (tool missing-tools)
      (push (format "missing %s %s: %s (%s)"
                    (plist-get tool :type)
                    (plist-get tool :name)
                    (plist-get tool :purpose)
                    (plist-get tool :install-hint))
            problems))
    (dolist (dep missing-packages)
      (push (format "missing package %s (%s)" (car dep) (cdr dep)) problems))
    (cons problems warnings)))

(defun kargu-config--report-setup (result)
  "Report setup dependencies and resolved credential RESULT."
  (let* ((key (and (kargu-ok-p result) (kargu-result-value result)))
         (report (kargu--setup-problems
                  key (and (fboundp 'kargu-deps-missing) (kargu-deps-missing))
                  (kargu--missing-dependencies)))
         (problems (car report))
         (warnings (cdr report)))
    (dolist (w warnings)
      (kargu-log 'warn "%s" w))
    (if problems
        (let ((msg (concat "kargu setup issues: "
                           (string-join (nreverse problems) "; "))))
          (kargu-log 'error "%s" msg)
          (message "%s" msg))
      (kargu-log 'info "setup check passed (provider=%s model=%s config=%s)"
                 (kargu--provider-name) (kargu--model) (kargu-config-file))
      (message "kargu ready: provider=%s model=%s, %s, config=%s, dependencies OK%s"
               (kargu--provider-name)
               (kargu--model)
               (cond
                ((null key) "no API key")
                ((string-empty-p key) "no Authorization header")
                ((kargu--api-key-placeholder-p key) "placeholder API key")
                (t "API key found"))
               (if (when-let* ((snapshot (kargu-config-service-snapshot
                                          (kargu-config-service-context))))
                     (kargu-config-snapshot-digest snapshot))
                   (kargu-config-file)
                 "not created yet")
               (if warnings
                   (concat " (warning: "
                           (string-join (nreverse warnings) "; ")
                           ")")
                 "")))))

(provide 'kargu/config/schema)

;;; schema.el ends here
