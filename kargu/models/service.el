;;; service.el --- Application ownership of provider metadata -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; One application owns UI catalog generations, cache and prefetch state.
;; Model records, overrides, capabilities and refusals live only in Rust.
;; Detached UI tables remain compatibility projections, not model authorities.

;;; Code:

(require 'kargu/application/coordinator)

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
