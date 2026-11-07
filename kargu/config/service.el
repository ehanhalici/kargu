;;; service.el --- Owned in-memory configuration publications -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Readers never touch files.  Rust orders each refresh, discovers, reads and
;; parses the file and stages it; this service only answers Rust's request for
;; named editor inputs and observes the committed view.  A defaults bootstrap
;; waits for a real refresh in flight instead of superseding it.

;;; Code:

(require 'cl-lib)
(require 'kargu/application/coordinator)
(require 'kargu/async)
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
  "Configuration publications and in-flight real refreshes for one owner."
  snapshot view-cell (revision 0) refreshes)

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

(defun kargu-config--failure (view failure)
  "Return a sanitized result error for a refresh VIEW or FAILURE."
  (let ((status (and (hash-table-p failure)
                     (let ((data (gethash "data" failure)))
                       (and (hash-table-p data) (gethash "status" data))))))
    (cond
     ((and (hash-table-p view) (equal (gethash "status" view) "invalid"))
      (let ((line (gethash "line" view)) (path (gethash "path" view)))
        (if (and (integerp line) (> line 0) (stringp path))
            (kargu-err (format "TOML %s:%d: Invalid configuration" path line) :config-unavailable)
          (kargu-err "Invalid or oversized native configuration result" :config-unavailable))))
     ((equal status "stale_configuration")
      (kargu-err "Configuration refresh was superseded" :stale))
     (t (kargu-err "Native config read failed; check TOML and rebuild kargu-core if outdated"
                   :config-unavailable)))))

(defun kargu-config--deliver-waiters (record result)
  "Deliver RESULT to RECORD's still-pending waiters, each on its own task."
  (dolist (waiter (prog1 (plist-get (cdr record) :waiters) (setcdr record nil)))
    (when (kargu-async-pending-p waiter)
      (kargu-async-finish waiter result))))

(cl-defun kargu-config-refresh-async (callback &key paths timeout parent owner defaults-only)
  "Refresh configuration into CALLBACK without UI file I/O.
PATHS are explicit file grants replacing native discovery; TIMEOUT, PARENT and
OWNER bound the task.  Positive TIMEOUT may shorten the fixed refresh deadline.
It cannot disable or extend that deadline.  DEFAULTS-ONLY bootstraps native
catalog/options without probing a config file and never supersedes a
publication or a real refresh; Rust decides both."
  (let* ((service (kargu-config-service-context))
         (app (kargu-application-context))
         (record (unless defaults-only (list :refresh)))
         (task (kargu-async-start
                (kargu-application-wrap
                 app (lambda (value error)
                       (setf (kargu-config-service-refreshes service)
                             (delq record (kargu-config-service-refreshes service)))
                       (let ((result
                              (condition-case nil
                                  (cond
                                   ((or error (kargu-err-p value))
                                    (or value (kargu-config--failure nil error)))
                                   (t (kargu-config--observe service (kargu-result-value value))
                                      (kargu-ok (kargu-config-current-snapshot))))
                                (error (kargu-err "Invalid or oversized native configuration result"
                                                  :config-unavailable)))))
                         (when record (kargu-config--deliver-waiters record result))
                         (funcall callback result))))
                :owner owner :parent parent
                :timeout (if (and (numberp timeout) (> timeout 0))
                             (min timeout kargu-config-refresh-default-timeout)
                           kargu-config-refresh-default-timeout))))
    (cond
     ((not (kargu-async-pending-p task)) (kargu-async-cancel task))
     ((<= (kargu-async-task-deadline task) (float-time))
      (kargu-async-finish task nil "Configuration deadline expired"))
     (t
      (when record
        (push record (kargu-config-service-refreshes service)))
      (kargu-bridge-config-refresh
       (kargu-async-wrap
        task (lambda (view failure)
               (if (and (not failure) (hash-table-p view)
                        (equal (gethash "status" view) "committed")
                        (natnump (gethash "revision" view))
                        (hash-table-p (gethash "config" view)))
                   (kargu-async-finish task (kargu-ok view))
                 (kargu-async-finish task (kargu-config--failure view failure)))))
       :paths paths :defaults-only defaults-only :parent task :application app)))
    task))

(cl-defun kargu-config-ensure-native-async (callback &key parent)
  "Ensure a committed native projection for explicit CALLBACK under PARENT.
An initialized view is only observed.  While a real refresh is in flight this
caller waits for it on its own task, so its deadline and cancellation stay
independent; otherwise a cold defaults bootstrap performs no file IO."
  (let* ((service (kargu-config-service-context))
         (record (car (kargu-config-service-refreshes service))))
    (cond
     ((kargu-config-native-view)
      (funcall callback (kargu-ok (kargu-config-current-snapshot))))
     (record
      (let ((waiter (kargu-async-start (lambda (value error)
                                         (funcall callback (or value (kargu-err error :config-unavailable))))
                                       :parent parent :owner nil
                                       :timeout kargu-config-refresh-default-timeout)))
        (when (kargu-async-pending-p waiter)
          (setcdr record (list :waiters (cons waiter (plist-get (cdr record) :waiters))))
          (kargu-async-add-cleanup
           waiter (lambda ()
                    (setcdr record (list :waiters (delq waiter (plist-get (cdr record) :waiters)))))))
        waiter))
     (t (kargu-config-refresh-async callback :parent parent :defaults-only t)))))


(provide 'kargu/config/service)
;;; service.el ends here
