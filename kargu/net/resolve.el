;;; resolve.el --- DNS lookup in an isolated Emacs process -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; The parent constructs an argv list; only the child calls the blocking
;; system resolver.  Stdout is numeric addresses, never evaluated Lisp.
;; Public-address policy is independently enforced by the parent.

;;; Code:

(require 'cl-lib)
(require 'puny)
(require 'kargu/net/address)

(defun kargu-resolver-command (host)
  "Return an executable argv for isolated HOST lookup, or nil.
Use the current Emacs executable and this installed library.  HOST is an
argument, never interpolated into evaluated Lisp or shell code."
  (when-let* ((program (executable-find (expand-file-name invocation-name invocation-directory)))
              (library (locate-library "kargu/net/resolve")))
    (list program "--batch" "-Q" "-L" (expand-file-name "../.." (file-name-directory library))
          "-l" library "-f" "kargu-resolver-main" host)))

(defun kargu-resolver--address (raw)
  "Convert one system-resolver address RAW to a numeric address string."
  (when (vectorp raw)
    (pcase (length raw)
      (5 (kargu-ip-format (cl-subseq raw 0 4)))
      (9 (kargu-ip-format
          (vconcat (cl-loop for index below 8 for word = (aref raw index)
                            append (list (ash word -8) (logand word 255)))))))))

(defun kargu-resolver--addresses (host)
  "Resolve HOST to numeric address strings; call only in the worker process.
The system call can block and must never run on the parent UI thread."
  (delete-dups
   (delq nil (mapcar #'kargu-resolver--address
                     (network-lookup-address-info (puny-encode-domain host))))))

(defun kargu-resolver-main ()
  "Resolve the single remaining command-line hostname and exit the worker."
  (let ((args command-line-args-left))
    (setq command-line-args-left nil)
    (condition-case nil
        (progn
          (unless (= (length args) 1) (error "Expected one hostname"))
          (let ((addresses (kargu-resolver--addresses (car args))))
            (princ (mapconcat #'identity addresses "\n"))
            (kill-emacs (if addresses 0 1))))
      (error (kill-emacs 1)))))

(provide 'kargu/net/resolve)
;;; resolve.el ends here
