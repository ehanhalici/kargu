;;; service.el --- Owned in-memory configuration publications -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Readers never touch files.  A bounded child refreshes one owner's config;
;; only its latest successful generation may publish a new revision.

;;; Code:

(require 'cl-lib)
(require 'kargu/application/coordinator)
(require 'kargu/async)
(require 'kargu/config/worker)
(require 'kargu/bridge/config)

(cl-defstruct (kargu-config-snapshot (:constructor kargu-config--snapshot))
  "One validated configuration publication, without filesystem readers."
  (path nil :read-only t) (digest nil :read-only t)
  (content nil :read-only t) (revision 0 :read-only t))

(cl-defun kargu-config-snapshot-create (&key path digest data (revision 0))
  "Capture PATH, DIGEST, DATA and REVISION without printing configuration keys."
  (let ((content (make-symbol "kargu-config-content")))
    (put content 'value (kargu-config-copy data))
    (kargu-config--snapshot :path (kargu-config-copy path)
                          :digest (kargu-config-copy digest)
                          :content content :revision revision)))

(defun kargu-config-snapshot-data (snapshot)
  "Return a detached copy of SNAPSHOT's configuration data."
  (kargu-config-copy (get (kargu-config-snapshot-content snapshot) 'value)))

(defun kargu-config-current-data ()
  "Return borrowed read-only config data for trusted in-process consumers."
  (when-let* ((snapshot (kargu-config-service-snapshot (kargu-config-service-context))))
    (get (kargu-config-snapshot-content snapshot) 'value)))

(cl-defstruct (kargu-config-service (:constructor kargu-config-service-create))
  "Configuration publications and pending refresh generation for one owner."
  snapshot (generation 0) (revision 0))

(defun kargu-config-service-context ()
  "Return the current application's configuration service."
  (kargu-application-service :config #'kargu-config-service-create))

(defun kargu-config-copy (value)
  "Detach VALUE's nested strings and containers at an ownership boundary."
  (cond
   ((stringp value) (copy-sequence value))
   ((consp value)
    (let ((tail value) items)
      (while (consp tail)
        (push (kargu-config-copy (car tail)) items)
        (setq tail (cdr tail)))
      (nconc (nreverse items) (kargu-config-copy tail))))
   ((vectorp value) (apply #'vector (mapcar #'kargu-config-copy value)))
   ((hash-table-p value)
    (let ((copy (make-hash-table :test (hash-table-test value))))
      (maphash (lambda (key item)
                 (puthash (kargu-config-copy key) (kargu-config-copy item) copy)) value)
      copy))
   (t value)))

(defun kargu-config-current-snapshot ()
  "Return a detached copy of the current validated configuration snapshot."
  (when-let* ((snapshot (kargu-config-service-snapshot (kargu-config-service-context))))
    (kargu-config-snapshot-create
     :path (kargu-config-copy (kargu-config-snapshot-path snapshot))
     :digest (kargu-config-copy (kargu-config-snapshot-digest snapshot))
     :data (kargu-config-copy (kargu-config-snapshot-data snapshot))
     :revision (kargu-config-snapshot-revision snapshot))))

(defun kargu-config-publish (service data path digest)
  "Publish validated DATA from PATH and DIGEST to SERVICE atomically."
  (let ((old (kargu-config-service-snapshot service)))
    (unless (and old (equal path (kargu-config-snapshot-path old))
                 (equal digest (kargu-config-snapshot-digest old)))
      (cl-incf (kargu-config-service-revision service))
      (setf (kargu-config-service-snapshot service)
            (kargu-config-snapshot-create
             :data data :path path :digest digest
             :revision (kargu-config-service-revision service))))
    (when (boundp 'kargu-diff-review-mode)
      (pcase (plist-get data :review-mode)
        ("auto" (setq kargu-diff-review-mode 'auto))
        ("async" (setq kargu-diff-review-mode 'async))
        ("blocking" (setq kargu-diff-review-mode 'blocking))))
    (kargu-config-service-snapshot service)))

(defun kargu-config--file-script ()
  "Return the fixed child entry point for bounded configuration reading."
  (prin1-to-string
   '(progn
      (require 'json)
      (require 'seq)
      (when (equal (car command-line-args-left) "--") (pop command-line-args-left))
      (let* ((paths (json-parse-string (pop command-line-args-left) :array-type 'list))
             (path (or (seq-find #'file-exists-p paths) (car paths))))
        (condition-case nil
            (let* ((exists (file-exists-p path))
                   (text (and exists (with-temp-buffer
                                       (unless (file-regular-p path) (error "Not a regular file"))
                                       (insert-file-contents path nil 0 65537)
                                       (buffer-string)))))
              (princ (json-serialize (list :path path :source text))))
          (error (princ "{\"error\":\"config-unavailable\"}")))))))

(defun kargu-config--decode-file (process buffer)
  "Decode PROCESS's bounded captured file text from BUFFER, without parsing TOML."
  (condition-case nil
      (let* ((result (and (= 0 (process-exit-status process))
                          (with-current-buffer buffer
                            (json-parse-string (buffer-string) :object-type 'plist
                                               :array-type 'list :null-object nil))))
             (source (plist-get result :source)))
        (unless (and (stringp (plist-get result :path)) (not (plist-get result :error)))
          (error "Invalid configuration response"))
        (unless (or (null source) (stringp source)) (error "Invalid configuration source"))
        (kargu-ok (list :source source :path (plist-get result :path))))
    (error (kargu-err "Configuration is unreadable or invalid; check the TOML file"
                       :config-unavailable))))

(defun kargu-config--editor-data (value)
  "Translate native VALUE into the existing read-only plist/alist UI projection."
  (let (data)
    (dolist (name '("provider" "model" "review-mode"))
      (let ((item (gethash name value)))
        (unless (or (stringp item) (eq item :json-null)) (error "Invalid config projection"))
        (setq data (plist-put data (intern (concat ":" name)) (unless (eq item :json-null) item)))))
    (let ((providers (gethash "providers" value)) entries)
      (unless (vectorp providers) (error "Invalid provider projection"))
      (mapc (lambda (entry)
              (let ((name (gethash "name" entry)) (fields (gethash "data" entry)) attributes)
                (unless (and (stringp name) (hash-table-p fields)) (error "Invalid provider projection"))
                (dolist (field '("api" "apikey" "model" "models"))
                  (when (gethash field fields)
                    (let ((item (gethash field fields)))
                      (if (equal field "models")
                          (progn
                            (unless (and (vectorp item) (cl-every #'stringp item)) (error "Invalid models projection"))
                            (setq item (append item nil)))
                        (unless (stringp item) (error "Invalid provider projection")))
                      (setq attributes (plist-put attributes (intern (concat ":" field)) item)))))
                (push (cons name attributes) entries))) providers)
      (plist-put data :providers (nreverse entries)))))

(defun kargu-config--parsed (task path generation value failure)
  "Complete TASK with native VALUE for PATH/GENERATION or sanitized FAILURE."
  (condition-case nil
      (cond
       (failure (kargu-async-finish task (kargu-err "Native config parser unavailable; check/rebuild kargu-core" :config-unavailable)))
       ((not (and (hash-table-p value) (equal generation (gethash "generation" value))))
        (error "Invalid config generation"))
       ((equal (gethash "status" value) "invalid")
        (let ((line (gethash "line" value)))
          (unless (and (integerp line) (> line 0)) (error "Invalid source line"))
          (kargu-async-finish task (kargu-err (format "TOML %s:%d: Invalid configuration" path line) :config-unavailable))))
       ((equal (gethash "status" value) "ok")
        (let ((digest (gethash "digest" value)) (config (gethash "config" value)))
          (unless (and (stringp digest) (string-match-p "\\`[0-9a-f]\\{64\\}\\'" digest)
                       (hash-table-p config)) (error "Invalid config projection"))
          (kargu-async-finish task (kargu-ok (list :data (kargu-config--editor-data config) :path path :digest digest)))))
       (t (error "Invalid config result")))
    (error (kargu-async-finish task (kargu-err "Invalid or oversized native configuration result" :config-unavailable)))))

(defun kargu-config--loaded (task application generation value)
  "Parse captured file VALUE for TASK/APPLICATION/GENERATION before publication."
  (let* ((data (and (kargu-ok-p value) (kargu-result-value value)))
         (source (plist-get data :source)) (path (plist-get data :path)))
    (unwind-protect
        (cond
         ((kargu-err-p value) (kargu-async-finish task value))
         ((/= generation (kargu-config-service-generation (kargu-config-service-context)))
          (kargu-async-finish task (kargu-err "Configuration refresh was superseded" :stale)))
         ((null source) (kargu-async-finish task (kargu-ok (list :data nil :path path :digest nil))))
         (t (kargu-bridge-config-parse
             source generation
             (kargu-async-wrap task (lambda (result failure) (kargu-config--parsed task path generation result failure)))
             :parent task :application application)))
      (when (stringp source) (clear-string source)))))

(cl-defun kargu-config-refresh-async (callback &key paths timeout parent owner)
  "Refresh configuration into CALLBACK without UI file I/O.
PATHS overrides candidate names; TIMEOUT, PARENT and OWNER bound the task.
Positive TIMEOUT may shorten the fixed worker deadline, never disable/extend it."
  (let* ((service (kargu-config-service-context))
         (generation nil)
         (app (kargu-application-context))
         (task (kargu-async-start
                (kargu-application-wrap
                 app (lambda (value error)
                       (cond
                        ((and generation (/= generation (kargu-config-service-generation service)))
                         (funcall callback (kargu-err "Configuration refresh was superseded" :stale)))
                        ((or error (kargu-err-p value))
                         (funcall callback (or value (kargu-err error :config-unavailable))))
                        (t
                         (let ((data (kargu-result-value value)))
                           (kargu-config-publish service (plist-get data :data)
                                                 (plist-get data :path) (plist-get data :digest))
                           (funcall callback (kargu-ok (kargu-config-current-snapshot))))))))
                :owner owner :parent parent
                :timeout (if (and (numberp timeout) (> timeout 0))
                             (min timeout kargu-config-worker-default-timeout)
                           kargu-config-worker-default-timeout))))
    (cond
     ((not (kargu-async-pending-p task)) (kargu-async-cancel task))
     ((<= (kargu-async-task-deadline task) (float-time))
      (kargu-async-finish task nil "Configuration deadline expired"))
     (t
      (setq generation (1+ (kargu-config-service-generation service)))
      (setf (kargu-config-service-generation service) generation)
      (let ((reader (kargu-async-start
                     (kargu-application-wrap
                      app (kargu-async-wrap task (lambda (value error-data)
                                                  (kargu-config--loaded task app generation
                                                                        (or value (kargu-err error-data :config-unavailable))))))
                     :parent task :owner nil)))
        (kargu-config-worker-start
         reader (kargu-config--file-script)
         (list (json-serialize (vconcat (or paths (list (kargu--xdg-config-file)
                                                       (locate-user-emacs-file "kargu.toml"))))))
         :max-bytes (+ (* 6 kargu-bridge-config-max-source-bytes) 8192)
         :decode #'kargu-config--decode-file :name "config"))))
    task))

(declare-function kargu--xdg-config-file "kargu/config/schema" ())

(provide 'kargu/config/service)
;;; service.el ends here
