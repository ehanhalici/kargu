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
(require 'kargu/bridge/config)
(require 'kargu/bridge/config-policy)

(defconst kargu-config-refresh-default-timeout 5.0
  "Maximum editor deadline for native file capture and configuration parsing.")

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

(defun kargu-config-native-view ()
  "Borrow the last native config projection without IO or core startup."
  (when-let* ((cell (kargu-config-service-view-cell (kargu-config-service-context))))
    (get cell 'value)))

(cl-defstruct (kargu-config-service (:constructor kargu-config-service-create))
  "Configuration publications and pending refresh generation for one owner."
  snapshot view-cell (generation 0) (revision 0))

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

(defun kargu-config-json-equal (left right)
  "Compare bounded JSON LEFT and RIGHT by value, including hash-table contents."
  (cond
   ((hash-table-p left)
    (and (hash-table-p right) (= (hash-table-count left) (hash-table-count right))
         (let ((same t) (missing (make-symbol "missing")))
           (maphash (lambda (key value)
                      (unless (kargu-config-json-equal value (gethash key right missing)) (setq same nil))) left)
           same)))
   ((vectorp left) (and (vectorp right) (= (length left) (length right))
			(cl-every #'kargu-config-json-equal left right)))
   (t (equal left right))))

(defun kargu-config-current-snapshot ()
  "Return a detached copy of the current validated configuration snapshot."
  (when-let* ((snapshot (kargu-config-service-snapshot (kargu-config-service-context))))
    (kargu-config-snapshot-create
     :path (kargu-config-copy (kargu-config-snapshot-path snapshot))
     :digest (kargu-config-copy (kargu-config-snapshot-digest snapshot))
     :data (kargu-config-copy (kargu-config-snapshot-data snapshot))
     :revision (kargu-config-snapshot-revision snapshot))))


(defun kargu-config--observe (service view)
  "Observe SERVICE's committed native VIEW; never allocate a config revision."
  (let* ((revision (gethash "revision" view))
         (data (unless (eq (gethash "absent" view) t)
                 (kargu-config--editor-data (gethash "config" view))))
         (path (gethash "path" view))
         (digest (gethash "digest" view))
         (old (kargu-config-service-snapshot service)))
    (unless (and (natnump revision) (> revision 0) (stringp path)
                 (or (stringp digest) (eq digest :json-null)))
      (error "Invalid native config publication"))
    (when (eq digest :json-null) (setq digest nil))
    (unless (and old (= revision (kargu-config-snapshot-revision old))
                 (equal path (kargu-config-snapshot-path old)) (equal digest (kargu-config-snapshot-digest old)))
      (setf (kargu-config-service-snapshot service)
            (kargu-config-snapshot-create :data data :path path :digest digest :revision revision)))
    (let ((cell (make-symbol "kargu-config-native-view")))
      (put cell 'value (kargu-config-copy view))
      (setf (kargu-config-service-view-cell service) cell
            (kargu-config-service-revision service) revision))
    (when (boundp 'kargu-diff-review-mode)
      (pcase (plist-get data :review-mode)
        ("auto" (setq kargu-diff-review-mode 'auto))
        ("async" (setq kargu-diff-review-mode 'async))
        ("blocking" (setq kargu-diff-review-mode 'blocking))))
    (let (missing)
      (mapc (lambda (profile) (setq missing (append (gethash "missing_environment" profile) missing)))
            (gethash "profiles" view))
      (dolist (name (delete-dups missing))
        (kargu-log 'warn "Configured environment variable %s is unset or empty; native policy tried remaining credential sources" name)))
    (kargu-config-service-snapshot service)))

(defun kargu-config--committed (task generation view failure)
  "Finish TASK only with a native committed VIEW for captured GENERATION."
  (if (and (not failure) (hash-table-p view)
           (equal (gethash "status" view) "committed")
           (equal (gethash "generation" view) generation)
           (natnump (gethash "revision" view))
           (hash-table-p (gethash "config" view)))
      (kargu-async-finish task (kargu-ok view))
    (kargu-async-finish task (kargu-err "Native config publication unavailable" :config-unavailable))))

(defun kargu-config--publish-native (task generation value)
  "Submit parsed VALUE for GENERATION under TASK's captured native owner."
  (let ((service (kargu-config-service-context)))
    (kargu-bridge-config-publish
     value generation (kargu-async-wrap task (lambda (view failure) (kargu-config--committed task generation view failure)))
     :parent task :application (kargu-application-context)
     :valid-p (lambda () (= generation (kargu-config-service-generation service))))))

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
       (failure (kargu-async-finish task (kargu-err "Native config read failed; check TOML and rebuild kargu-core if outdated" :config-unavailable)))
       ((/= generation (kargu-config-service-generation (kargu-config-service-context)))
        (kargu-async-finish task (kargu-err "Configuration refresh was superseded" :stale)))
       ((not (and (hash-table-p value) (equal generation (gethash "generation" value))
                  (stringp path) (equal path (gethash "path" value))))
        (error "Invalid config generation"))
       ((equal (gethash "status" value) "absent")
        (kargu-config--publish-native task generation value))
       ((equal (gethash "status" value) "invalid")
        (let ((line (gethash "line" value)))
          (unless (and (integerp line) (> line 0)) (error "Invalid source line"))
          (kargu-async-finish task (kargu-err (format "TOML %s:%d: Invalid configuration" path line) :config-unavailable))))
       ((equal (gethash "status" value) "ok")
        (let ((digest (gethash "digest" value)) (config (gethash "config" value)))
          (unless (and (stringp digest) (string-match-p "\\`[0-9a-f]\\{64\\}\\'" digest)
                       (hash-table-p config)) (error "Invalid config projection"))
          (kargu-config--publish-native task generation value)))
       (t (error "Invalid config result")))
    (error (kargu-async-finish task (kargu-err "Invalid or oversized native configuration result" :config-unavailable)))))

(cl-defun kargu-config-refresh-async (callback &key paths timeout parent owner defaults-only)
  "Refresh configuration into CALLBACK without UI file I/O.
PATHS overrides candidate names; TIMEOUT, PARENT and OWNER bound the task.
Positive TIMEOUT may shorten the fixed refresh deadline.
It cannot disable or extend that deadline.
DEFAULTS-ONLY bootstraps native catalog/options without probing a config file."
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
                         (let ((view (kargu-result-value value)))
                           (kargu-config--observe service view)
                           (funcall callback (kargu-ok (kargu-config-current-snapshot))))))))
                :owner owner :parent parent
                :timeout (if (and (numberp timeout) (> timeout 0))
                             (min timeout kargu-config-refresh-default-timeout)
                           kargu-config-refresh-default-timeout))))
    (cond
     ((not (kargu-async-pending-p task)) (kargu-async-cancel task))
     ((<= (kargu-async-task-deadline task) (float-time))
      (kargu-async-finish task nil "Configuration deadline expired"))
     (t
      (setq generation (1+ (kargu-config-service-generation service)))
      (setf (kargu-config-service-generation service) generation)
      (if defaults-only
          (kargu-config--parsed task (kargu--xdg-config-file) generation
                                (kargu-bridge--object "path" (kargu--xdg-config-file) "generation" generation "status" "absent") nil)
        (kargu-bridge-config-read
         (or paths (list (kargu--xdg-config-file) (locate-user-emacs-file "kargu.toml"))) generation
         (kargu-async-wrap task (lambda (value failure)
                                  (kargu-config--parsed task (and (hash-table-p value) (gethash "path" value))
                                                        generation value failure)))
         :parent task :application app))))
    task))

(cl-defun kargu-config-ensure-native-async (callback &key parent)
  "Ensure a committed native projection for explicit CALLBACK under PARENT.
An initialized view is only observed; a cold defaults view performs no file IO."
  (if (kargu-config-native-view)
      (funcall callback (kargu-ok (kargu-config-current-snapshot)))
    (kargu-config-refresh-async callback :parent parent :defaults-only t)))

(declare-function kargu--xdg-config-file "kargu/config/schema" ())

(provide 'kargu/config/service)
;;; service.el ends here
