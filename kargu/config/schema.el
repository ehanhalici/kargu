;;; kargu/config/schema.el --- Configuration cache and setup verification -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Configuration file cache, setup check verification, and provider switching.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
;; Ensure the package root is on `load-path' during byte/native
;; compilation from a subdirectory (Magit-style kargu/core features).
(eval-and-compile
  (let ((root (locate-dominating-file
               (or (bound-and-true-p byte-compile-current-file)
                   load-file-name
                   buffer-file-name
                   default-directory)
               "kargu.el")))
    (when root
      (add-to-list 'load-path (file-name-as-directory
                               (expand-file-name root))))))

(require 'kargu/core)
(require 'kargu/state)
(require 'kargu/config/toml)
(require 'kargu/config/key)

(defvar kargu--config-cache nil
  "Cached TOML config plist (:provider :model :providers), or nil.")

(defvar kargu--config-mtime nil
  "Modification time of the TOML file last read into `kargu--config-cache'.")

(defvar kargu--config-cache-path nil
  "Path of the TOML file last read into `kargu--config-cache'.")

(defun kargu--xdg-config-file ()
  "Return `$XDG_CONFIG_HOME/kargu/config.toml' (default ~/.config/...)."
  (expand-file-name
   "kargu/config.toml"
   (or (and (stringp (getenv "XDG_CONFIG_HOME"))
            (not (string-empty-p (getenv "XDG_CONFIG_HOME")))
            (getenv "XDG_CONFIG_HOME"))
       (expand-file-name ".config" (or (getenv "HOME") "~")))))

(defun kargu-config-file ()
  "Return the local TOML path: existing XDG file, else existing
`locate-user-emacs-file' kargu.toml, else the XDG path (to create)."
  (let ((xdg (kargu--xdg-config-file))
        (emacs (locate-user-emacs-file "kargu.toml")))
    (cond
     ((file-exists-p xdg) xdg)
     ((file-exists-p emacs) emacs)
     (t xdg))))

(defun kargu--config-plist ()
  "Return the TOML config plist, rereading when the file changes."
  (let ((path (kargu-config-file)))
    (if (not (file-readable-p path))
        (setq kargu--config-cache nil
              kargu--config-mtime nil
              kargu--config-cache-path path)
      (let ((mtime (file-attribute-modification-time (file-attributes path))))
        (unless (and (equal path kargu--config-cache-path)
                     (equal mtime kargu--config-mtime))
          (setq kargu--config-cache-path path
                kargu--config-mtime mtime
                kargu--config-cache
                (condition-case err
                    (kargu--read-toml-config path)
                  (error
                   (kargu-log 'warn "config %s: %s" path
                              (error-message-string err))
                   nil))))
        kargu--config-cache))))

(defun kargu--config-providers ()
  "Alist of (NAME . PLIST) for `[providers.*]' tables."
  (plist-get (kargu--config-plist) :providers))

(defun kargu-set-provider (name)
  "Use provider NAME for this Emacs session.
NAME can be any configured provider from TOML or any known provider
from `kargu-provider-list'."
  (interactive
   (let* ((cfg-names (mapcar #'car (kargu--config-providers)))
          (all-names (kargu-provider-list))
          (choices (delete-dups (append cfg-names all-names))))
     (unless choices
       (user-error "kargu: no providers available"))
     (list (completing-read "kargu provider: " choices nil nil
                            nil nil (kargu--provider-name)))))
  (setq kargu--session-provider name)
  (kargu-state-set-provider (if (symbolp name) name (intern name)))
  (let* ((prov-plist (kargu--provider-plist))
         (explicit-model (plist-get prov-plist :model))
         (cached-model (and (boundp 'kargu--live-models-cache)
                            (car-safe (gethash name kargu--live-models-cache)))))
    (setq kargu--session-model (or (kargu--nonempty explicit-model)
                                  (and noninteractive cached-model)))
    (when kargu--session-model
      (kargu-state-set-model kargu--session-model)))
  (when (fboundp 'kargu-api-prefetch-models)
    (kargu-api-prefetch-models name))
  (kargu-log 'info "provider set to %s (model %s, api %s)"
             name (or (kargu--model) "none") (kargu--api-base))
  (message "kargu provider: %s (model %s, api %s)"
           name (or (kargu--model) "none") (kargu--api-base))
  name)

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
                    "provider = \"openrouter\"\n"
                    "model = \"anthropic/claude-3.5-sonnet\"\n\n"
                    "[providers.openrouter]\n"
                    "api = \"https://openrouter.ai/api/v1\"\n"
                    "apikey = \"sk-or-v1-...\"\n"
                    "models = [\"anthropic/claude-3.5-sonnet\"]\n"))))
      (kargu-log 'info "created config %s" path)
      (message "kargu: created %s — fill in apikey" path))
    (find-file path)))

(defconst kargu--dependencies
  '((plz . "asynchronous HTTP + SSE streaming (mandatory)")
    (transient . "menu interface (mandatory)")
    (eglot . "LSP client (tools: skeleton, diagnostics, xref)")
    (dape . "debugger client (tools: stack, variables, eval)")
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

(defun kargu-check-setup ()
  "Check API key and dependencies; report in echo area and log."
  (interactive)
  (let* ((missing (kargu--missing-dependencies))
         (key (kargu--resolve-api-key))
         problems
         warnings)
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
    (dolist (dep missing)
      (push (format "missing package %s (%s)" (car dep) (cdr dep)) problems))
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
               (if (file-readable-p (kargu-config-file))
                   (kargu-config-file)
                 "not created yet")
               (if warnings
                   (concat " (warning: "
                           (string-join (nreverse warnings) "; ")
                           ")")
                 "")))))

(provide 'kargu/config/schema)

;;; kargu/config/schema.el ends here
