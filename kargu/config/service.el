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
(require 'kargu/config/toml)

(defconst kargu-config--parser-file
  (expand-file-name "toml.el" (file-name-directory (or load-file-name buffer-file-name)))
  "Parser library loaded by the isolated configuration worker.")

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
    (kargu--toml-apply-review-mode (plist-get data :review-mode))
    (kargu-config-service-snapshot service)))

(defun kargu-config--file-script ()
  "Return the fixed child entry point for bounded configuration reading."
  (prin1-to-string
   '(progn
      (require 'json)
      (require 'seq)
      (when (equal (car command-line-args-left) "--") (pop command-line-args-left))
      (load (pop command-line-args-left) nil t)
      (let* ((paths (json-parse-string (pop command-line-args-left) :array-type 'list))
             (path (or (seq-find #'file-exists-p paths) (car paths))))
        (condition-case nil
            (let* ((exists (file-exists-p path))
                   (text (and exists (with-temp-buffer
                                       (insert-file-contents path) (buffer-string))))
                   (data (and exists (kargu--read-toml-config path text)))
                   (digest (and exists (secure-hash 'sha256 text))))
              (when data
                (setq data (plist-put data :providers
                                      (vconcat (mapcar (lambda (entry)
                                                         (list :name (car entry) :data (cdr entry)))
                                                       (plist-get data :providers))))))
              (princ (json-serialize (list :path path :digest digest :config data))))
          (error (princ "{\"error\":\"config-unavailable\"}")))))))

(defun kargu-config--decode-file (process buffer)
  "Decode PROCESS's validated JSON configuration from BUFFER."
  (condition-case nil
      (let* ((result (and (= 0 (process-exit-status process))
                          (with-current-buffer buffer
                            (json-parse-string (buffer-string) :object-type 'plist
                                               :array-type 'list :null-object nil))))
             (data (plist-get result :config)))
        (unless (and (stringp (plist-get result :path)) (not (plist-get result :error)))
          (error "Invalid configuration response"))
        (when data
          (setq data (plist-put data :providers
                                (mapcar (lambda (entry)
                                          (cons (plist-get entry :name) (plist-get entry :data)))
                                        (plist-get data :providers)))))
        (kargu-ok (list :data data :path (plist-get result :path)
                        :digest (plist-get result :digest))))
    (error (kargu-err "Configuration is unreadable or invalid; check the TOML file"
                       :config-unavailable))))

(cl-defun kargu-config-refresh-async (callback &key paths timeout parent owner)
  "Refresh configuration into CALLBACK without UI file I/O.
PATHS overrides candidate names; TIMEOUT, PARENT and OWNER bound the task."
  (let* ((service (kargu-config-service-context))
         (generation (cl-incf (kargu-config-service-generation service)))
         (app (kargu-application-context))
         (task (kargu-async-start
                (kargu-application-wrap
                 app (lambda (value error)
                       (cond
                        ((/= generation (kargu-config-service-generation service))
                         (funcall callback (kargu-err "Configuration refresh was superseded" :stale)))
                        ((or error (kargu-err-p value))
                         (funcall callback (or value (kargu-err error :config-unavailable))))
                        (t
                         (let ((data (kargu-result-value value)))
                           (kargu-config-publish service (plist-get data :data)
                                                 (plist-get data :path) (plist-get data :digest))
                           (funcall callback (kargu-ok (kargu-config-current-snapshot))))))))
                :owner owner :parent parent
                :timeout (or timeout kargu-config-worker-default-timeout))))
    (kargu-config-worker-start
     task (kargu-config--file-script)
     (list kargu-config--parser-file
           (json-serialize (vconcat (or paths (list (kargu--xdg-config-file)
                                                   (locate-user-emacs-file "kargu.toml"))))))
     :decode #'kargu-config--decode-file :name "config")
    task))

(declare-function kargu--xdg-config-file "kargu/config/schema" ())

(provide 'kargu/config/service)
;;; service.el ends here
