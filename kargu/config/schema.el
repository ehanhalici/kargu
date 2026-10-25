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
(require 'kargu/config/toml)
(require 'kargu/config/key)
(require 'kargu/config/service)
(require 'kargu/models/service)

(defun kargu-config-revision ()
  "Return current monotonic integer revision of the configuration."
  (kargu-config-service-revision (kargu-config-service-context)))

(defun kargu-config-bump-revision ()
  "Invalidate pending configuration consumers on this owner."
  (cl-incf (kargu-config-service-revision (kargu-config-service-context))))

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

(defun kargu-set-provider (name &optional no-model)
  "Use provider NAME for the current owned session.
NAME can be any configured provider from TOML or any known provider
from `kargu-provider-list'.  NO-MODEL leaves the model choice empty for
the native UI's separate model-selection step."
  (interactive
   (let* ((cfg-names (mapcar #'car (kargu--config-providers)))
          (all-names (kargu-provider-list))
          (choices (delete-dups (append cfg-names all-names))))
     (unless choices
       (user-error "Kargu: no providers available"))
     (list (completing-read "kargu provider: " choices nil t
                            nil nil (kargu--provider-name)))))
  (let* ((name (if (symbolp name) (symbol-name name) name))
         (prov-plist (kargu--provider-plist name))
         (explicit-model (plist-get prov-plist :model))
         (cached-model (and (boundp 'kargu--live-models-cache)
                            (car-safe (gethash name (kargu-metadata-table :catalog kargu--live-models-cache))))))
    (when (kargu-selection-update :provider name
				  :model (unless no-model
					   (or (kargu-nonempty explicit-model)
                                               (and noninteractive cached-model)))
				  :effort nil)
      (when (fboundp 'kargu-api-prefetch-models)
	(kargu-api-prefetch-models name))
      (kargu-log 'info "provider set to %s (model %s, api %s)"
		 name (or (kargu--model) "none") (kargu--api-base))
      (message "kargu provider: %s (model %s, api %s)"
               name (or (kargu--model) "none") (kargu--api-base))
      name)))

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
              (format "API key looks like a placeholder (%s)" key))
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

(defun kargu-check-setup ()
  "Check configuration and credentials asynchronously, then report dependencies."
  (interactive)
  (kargu-config-refresh-async
   (lambda (result)
     (if (kargu-err-p result)
         (message "Kargu: %s" (kargu-result-err-message result))
       (kargu-config-resolve-api-key-async nil #'kargu-config--report-setup)))))

(provide 'kargu/config/schema)

;;; schema.el ends here
