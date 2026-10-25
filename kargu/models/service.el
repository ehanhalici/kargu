;;; service.el --- Application ownership of provider metadata -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; One application owns catalog generations, model records, refusals and
;; circuit records.  Legacy tables remain bridges for detached consumers.

;;; Code:

(require 'kargu/application/coordinator)

(defun kargu-metadata-assert-legacy-writer ()
  "Refuse a legacy write after this application enters native publication.
The default producer cutover is separate; never silently run two writers."
  (when (gethash :native-models (kargu-application-services (kargu-application-context)))
    (user-error "Kargu: native metadata publication owns this application")))

(defun kargu-metadata-table (name legacy)
  "Return the application's table NAME, or detached compatibility table LEGACY."
  (if (and (not kargu-metadata--legacy)
           (or kargu-application--bound kargu-application-owner))
      (let ((tables (kargu-application-service
                     :metadata (lambda () (make-hash-table :test #'eq)))))
        (or (gethash name tables)
            (puthash name (make-hash-table :test #'equal) tables)))
    legacy))

(provide 'kargu/models/service)
;;; service.el ends here
