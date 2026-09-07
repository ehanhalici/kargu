;;; kargu/config.el --- TOML config, provider, API key -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Local TOML (`~/.config/kargu/config.toml`), active provider,
;; endpoint URL, model id, API key resolution, and setup check.
;;
;; Requires: `kargu/core'.
;; Public: `kargu-config-file', `kargu-edit-config',
;; `kargu-set-provider', `kargu-check-setup'.

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
(require 'kargu/providers)

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

(defun kargu--toml-unescape (string)
  "Undo basic TOML escapes in STRING (the inside of a quoted value)."
  (replace-regexp-in-string
   "\\\\\\(.\\)"
   (lambda (m)
     (pcase (aref m 1)
       (?n "\n") (?t "\t") (?r "\r")
       (?\" "\"") (?\\ "\\")
       (_ (substring m 1))))
   string t t))

(defun kargu--toml-array-closed-p (raw)
  "Non-nil when RAW contains a `[' later closed by a `]'."
  (let ((open (cl-position ?\[ raw))
        (close (cl-position ?\] raw :from-end t)))
    (and open close (> close open))))

(defun kargu--toml-parse-string-array (raw)
  "Parse a TOML string array RAW like [\"a\", \"b\"] or [`a', `b']."
  (setq raw (or raw ""))
  (let ((open (cl-position ?\[ raw))
        (close (cl-position ?\] raw :from-end t)))
    (when (and open close (> close open))
      (let (items)
        (with-temp-buffer
          (insert (substring raw (1+ open) close))
          (goto-char (point-min))
          (while (re-search-forward
                  "\\(?:\"\\(\\(?:\\\\.\\|[^\"\\\\]\\)*\\)\"\\|'\\([^']*\\)'\\)" nil t)
            (if (match-string 1)
                (push (kargu--toml-unescape (match-string 1)) items)
              (push (match-string 2) items))))
        (nreverse items)))))

(defun kargu--toml-parse-value (raw)
  "Parse a TOML value RAW.
RAW may be a quoted string, single-quoted string, array, or bare token."
  (setq raw (string-trim (or raw "")))
  (cond
   ((string-prefix-p "[" raw)
    (kargu--toml-parse-string-array raw))
   ((string-prefix-p "\"" raw)
    (if (string-match "\\`\"\\(\\(?:\\\\.\\|[^\"\\\\]\\)*\\)\"" raw)
        (kargu--toml-unescape (match-string 1 raw))
      (string-trim raw "\"" "\"")))
   ((string-prefix-p "'" raw)
    (if (string-match "\\`'\\([^']*\\)'" raw)
        (match-string 1 raw)
      (string-trim raw "'" "'")))
   (t
    (let ((bare (car (split-string raw "#" t "[ \t]+"))))
      (and bare (string-trim bare))))))

(defun kargu--provider-plist-put (providers name key value)
  "Set KEY to VALUE on provider NAME in PROVIDERS (alist of name . plist)."
  (let ((cell (assoc name providers)))
    (if cell
        (progn (setcdr cell (plist-put (cdr cell) key value)) providers)
      (cons (cons name (list key value)) providers))))

(defun kargu--read-toml-config (path)
  "Read PATH as kargu TOML; return (:provider :model :providers)."
  (let (top-provider top-model top-name top-api top-key top-review-mode
        providers
        (section nil))
    (with-temp-buffer
      (insert-file-contents path)
      (goto-char (point-min))
      (while (not (eobp))
        (let ((line (string-trim
                     (buffer-substring (line-beginning-position)
                                       (line-end-position)))))
          (cond
           ((or (string-empty-p line) (eq (aref line 0) ?#))
            nil)
           ((string-match
             "\\`\\[providers?\\.\\([A-Za-z][A-Za-z0-9_-]*\\)\\]\\'" line)
            (setq section (match-string 1 line)))
           ((eq (aref line 0) ?\[)
            (setq section 'skip))
           ((eq section 'skip)
            nil)
           ((string-match
             "\\`\\([A-Za-z][A-Za-z0-9_]*\\)[ \t]*=[ \t]*\\(.*\\)\\'"
             line)
            (let ((key (match-string 1 line))
                  (raw (match-string 2 line)))
              (when (and (string-prefix-p "[" (string-trim raw))
                         (not (kargu--toml-array-closed-p raw)))
                (catch 'kargu--toml-array-end
                  (while (not (kargu--toml-array-closed-p raw))
                    (let ((here (point)))
                      (forward-line 1)
                      (when (or (eobp) (= (point) here))
                        (throw 'kargu--toml-array-end nil))
                      (setq raw
                            (concat raw " "
                                    (string-trim
                                     (buffer-substring
                                      (line-beginning-position)
                                      (line-end-position)))))))))
              (kargu--read-toml-assign
               section key
               (kargu--toml-parse-value raw)
               (lambda (k v)
                 (pcase k
                   ("provider" (setq top-provider v))
                   ("model" (setq top-model v))
                   ("name" (setq top-name v))
                   ("api" (setq top-api v))
                   ("apikey" (setq top-key v))
                   ("review_mode" (setq top-review-mode v))))
               (lambda (s k v)
                 (setq providers
                       (kargu--provider-plist-put providers s k v))))))))
        (forward-line 1)))
    (setq providers (nreverse providers))
    (when (and (null providers) (or top-api top-key top-name top-model))
      (setq providers
            (list (cons "default"
                        (append (and top-api (list :api top-api))
                                (and top-key (list :apikey top-key))
                                (let ((id (or top-model top-name)))
                                  (and id (list :models (list id)))))))))
    (when (and (stringp top-review-mode) (boundp 'kargu-diff-review-mode))
      (let ((m (intern (downcase (string-trim top-review-mode)))))
        (when (memq m '(auto blocking async))
          (setq kargu-diff-review-mode m))))
    (list :provider (kargu--nonempty top-provider)
          :model (or (kargu--nonempty top-model)
                     (kargu--nonempty top-name))
          :review-mode (kargu--nonempty top-review-mode)
          :providers providers)))

(defun kargu--read-toml-assign (section key val top-fn provider-fn)
  "Apply KEY=VAL from SECTION via TOP-FN or PROVIDER-FN."
  (if (null section)
      (funcall top-fn key val)
    (pcase key
      ("api" (funcall provider-fn section :api val))
      ("apikey" (funcall provider-fn section :apikey val))
      ("model" (funcall provider-fn section :model val))
      ("models" (when (listp val)
                  (funcall provider-fn section :models val))))))

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

(defun kargu--provider-name ()
  "Name of the active provider."
  (or (kargu--nonempty kargu--session-provider)
      (kargu--nonempty (plist-get (kargu--config-plist) :provider))
      (caar (kargu--config-providers))
      "default"))

(defun kargu--provider-plist ()
  "Plist for the active provider (`:api', `:apikey', `:models').
Merges user TOML configuration with built-in provider defaults."
  (let* ((name (kargu--provider-name))
         (entry (assoc name (kargu--config-providers)))
         (default-info (kargu-provider-get name))
         (toml-plist (cond
                      (entry (cdr entry))
                      (default-info nil)
                      (t (cdr (car (kargu--config-providers)))))))
    (append toml-plist
            (when (and default-info (null (plist-get toml-plist :api)))
              (let ((default-api (plist-get default-info :api)))
                (and (kargu--nonempty default-api)
                     (list :api default-api))))
            (when (and default-info (null (plist-get toml-plist :models)))
              (let ((default-models (plist-get default-info :models)))
                (and default-models
                     (list :models default-models)))))))

(defun kargu--provider-models ()
  "Model id strings listed on the active provider, or nil."
  (let ((models (plist-get (kargu--provider-plist) :models)))
    (and (listp models) models)))

(defun kargu--strip-trailing-slashes (url)
  "Return URL without a trailing slash."
  (if (and (stringp url) (not (string-empty-p url)))
      (replace-regexp-in-string "/+\\'" "" url)
    url))

(defun kargu--api-base (&optional provider-name)
  "Return endpoint base URL.
Use active or specified PROVIDER-NAME `api', else `kargu-api-base'."
  (kargu--strip-trailing-slashes
   (or (and provider-name
            (fboundp 'kargu-provider-api)
            (kargu-provider-api provider-name))
       (kargu--nonempty (plist-get (kargu--provider-plist) :api))
       kargu-api-base)))

(defun kargu--model ()
  "Model id: session model, explicit TOML model, or nil if not selected yet."
  (or (kargu--nonempty kargu--session-model)
      (and (null kargu--session-provider)
           (kargu--nonempty (plist-get (kargu--config-plist) :model)))
      (kargu--nonempty (plist-get (kargu--provider-plist) :model))))

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
  (let* ((prov-plist (kargu--provider-plist))
         (explicit-model (plist-get prov-plist :model))
         (cached-model (and (boundp 'kargu--live-models-cache)
                            (car-safe (gethash name kargu--live-models-cache)))))
    (setq kargu--session-model (or (kargu--nonempty explicit-model)
                                  (and noninteractive cached-model))))
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

(declare-function url-host "url-parse")
(declare-function url-generic-parse-url "url-parse")
(declare-function auth-source-search "auth-source")

(defun kargu--url-host (url)
  "Host name of URL, or nil."
  (when (kargu--nonempty url)
    (require 'url-parse)
    (url-host (url-generic-parse-url url))))

(defconst kargu--env-key-by-host
  '(("openrouter\\.ai\\'" . "OPENROUTER_API_KEY")
    ("openai\\.com\\'" . "OPENAI_API_KEY")
    ("anthropic\\.com\\'" . "ANTHROPIC_API_KEY"))
  "Alist of host regexp to environment variable name.")

(defun kargu--env-api-key (host)
  "Environment API key for endpoint HOST, or nil."
  (when host
    (let ((entry (cl-find-if (lambda (cell) (string-match-p (car cell) host))
                             kargu--env-key-by-host)))
      (and entry (getenv (cdr entry))))))

(defun kargu--api-key-placeholder-p (key)
  "Non-nil if KEY is empty or a documented dummy placeholder."
  (and (stringp key)
       (let ((k (downcase (string-trim key))))
         (or (string-empty-p k)
             (member k '("dummy" "none" "opencode-free" "placeholder" "..."))
             (string-suffix-p "..." k)))))

(defun kargu--provider-env-api-key ()
  "API key from environment variables associated with active provider, or nil."
  (let ((envs (kargu-provider-env (kargu--provider-name))))
    (cl-some (lambda (var)
               (let ((val (getenv var)))
                 (and (kargu--nonempty val) val)))
             envs)))

(defun kargu--resolve-api-key (&optional provider-name)
  "Resolve the API key for the active or specified PROVIDER-NAME."
  (if (and provider-name
           (not (equal provider-name (kargu--provider-name))))
      (let* ((pname-str (if (symbolp provider-name) (symbol-name provider-name) (format "%s" provider-name)))
             (pname-lower (downcase (string-trim pname-str)))
             (entry (assoc pname-lower (kargu--config-providers)))
             (toml-plist (and entry (cdr entry)))
             (envs (and (fboundp 'kargu-provider-env) (kargu-provider-env pname-lower)))
             (env-val (cl-some (lambda (v) (let ((val (getenv v))) (and (kargu--nonempty val) val))) envs)))
        (or (and toml-plist (kargu--nonempty (plist-get toml-plist :apikey)))
            (kargu--nonempty env-val)
            (and (equal pname-lower (kargu--provider-name)) (kargu--nonempty kargu-api-key))
            (and toml-plist (plist-member toml-plist :apikey) "")
            nil))
    (cond
     ((kargu--nonempty kargu-api-key))
     ((kargu--nonempty (plist-get (kargu--provider-plist) :apikey)))
     ((kargu--nonempty (kargu--provider-env-api-key)))
     ((kargu--nonempty (kargu--env-api-key (kargu--url-host (kargu--api-base)))))
     ((let* ((host (or (kargu--url-host (kargu--api-base)) "openrouter.ai"))
             (found (progn (require 'auth-source)
                           (auth-source-search :host host :max 1))))
        (when found
          (let ((secret (plist-get (car found) :secret)))
            (kargu--nonempty
             (cond
              ((functionp secret) (funcall secret))
              ((stringp secret) secret)))))))
     ((plist-member (kargu--provider-plist) :apikey) "")
     (t nil))))

(defconst kargu--dependencies
  '((plz . "asynchronous HTTP + SSE streaming (mandatory)")
    (transient . "menu interface (mandatory)")
    (lsp-mode . "LSP client (tools: skeleton, diagnostics, xref)")
    (dape . "debugger client (tools: stack, variables, eval)")
    (ediff . "diff approval engine (built into Emacs)"))
  "Feature -> purpose map checked by `kargu-check-setup'.")

(defun kargu--missing-dependencies ()
  "Return a list of (FEATURE . PURPOSE) for missing packages."
  (cl-remove-if (lambda (dep)
                  (or (featurep (car dep))
                      (locate-library (symbol-name (car dep)))))
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

(provide 'kargu/config)

;;; kargu/config.el ends here
