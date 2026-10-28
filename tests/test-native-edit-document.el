;;; test-native-edit-document.el --- Editor transaction facts -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Real buffers, markers, undo and save hooks.  No fake applied classification.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'kargu/bridge/edit/document)

(defmacro kargu-edit-document-test--with-file (text &rest body)
  "Visit a private file containing TEXT and evaluate BODY."
  (declare (indent 1) (debug t))
  `(let* ((directory (make-temp-file "kargu-document-" t))
          (file (expand-file-name "source" directory))
          buffer)
     (unwind-protect
         (progn
           (write-region ,text nil file nil 'silent)
           (setq buffer (find-file-noselect file))
           (with-current-buffer buffer ,@body))
       (when (buffer-live-p buffer)
         (with-current-buffer buffer (set-buffer-modified-p nil))
         (kill-buffer buffer))
       (delete-directory directory t))))

(ert-deftest kargu-native-edit-document-preserves-markers-narrowing-and-undo-test ()
  (kargu-edit-document-test--with-file "first\nstable 🦀\nlast\n"
    (buffer-enable-undo)
    (setq buffer-undo-list nil)
    (goto-char 10)
    (set-mark 13)
    (let ((marker (copy-marker 11))
          (snapshot (kargu-bridge-edit-document-capture buffer)))
      (narrow-to-region 7 16)
      (let ((observation
             (kargu-bridge-edit-document-replace
              snapshot "prefix\nfirst\nstable 🦀\nlast\n"
              :check-issued (lambda () t) :save nil)))
        (should-not (kargu-bridge-edit-document-change-failure observation))
        (should (eq (kargu-bridge-edit-document-change-stage observation) :replaced))
        (should (buffer-narrowed-p))
        (should (= (point-min) 14))
        (should (= (point) 17))
        (should (= (mark) 20))
        (should (= marker 18))
        (should (equal (buffer-substring-no-properties (point-min) (point-max)) "stable 🦀\n"))
        (widen)
        (undo-only 1)
        (should (equal (buffer-string) "first\nstable 🦀\nlast\n"))
        (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string))
                       "first\nstable 🦀\nlast\n")))
      (set-marker marker nil))))

(ert-deftest kargu-native-edit-document-rejects-stale-dirty-readonly-and-replay-test ()
  (dolist (mutation '(:tick :dirty :readonly :coding :disk :path :revoked))
    (kargu-edit-document-test--with-file "old\n"
      (let ((snapshot (kargu-bridge-edit-document-capture buffer)))
        (pcase mutation
          (:tick (insert "foreign") (set-buffer-modified-p nil))
          (:dirty (set-buffer-modified-p t))
          (:readonly (setq buffer-read-only t))
          (:coding (setq buffer-file-coding-system 'utf-16le))
          (:disk (write-region "foreign\n" nil file nil 'silent))
          (:path (setq buffer-file-name (expand-file-name "other" directory))))
        (let* ((before (buffer-string))
               (observation
                (kargu-bridge-edit-document-replace
                 snapshot "new\n" :save t
                 :check-issued (lambda () (not (eq mutation :revoked))))))
          (should (eq (kargu-bridge-edit-document-change-stage observation) :not-entered))
          (should (kargu-bridge-edit-document-change-failure observation))
          (should (equal (buffer-string) before))
          (should-error
           (kargu-bridge-edit-document-replace snapshot "new\n" :check-issued (lambda () t))
           :type 'kargu-bridge-edit-document-consumed))))))

(ert-deftest kargu-native-edit-document-check-callback-cannot-change-the-witness-test ()
  (kargu-edit-document-test--with-file "old\n"
    (let* ((snapshot (kargu-bridge-edit-document-capture buffer))
           (observation
            (kargu-bridge-edit-document-replace
             snapshot "new\n" :save t
             :check-issued (lambda () (insert "foreign") t))))
      (should (eq (kargu-bridge-edit-document-change-stage observation) :not-entered))
      (should (equal (buffer-string) "foreignold\n"))
      (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string)) "old\n")))))

(ert-deftest kargu-native-edit-document-save-hook-final-text-and-crlf-test ()
  (kargu-edit-document-test--with-file "old\r\n"
    (let ((snapshot (kargu-bridge-edit-document-capture buffer)))
      (add-hook 'before-save-hook (lambda () (goto-char (point-max)) (insert "hook 🦀\n")) nil t)
      (let* ((observation
              (kargu-bridge-edit-document-replace
               snapshot "new ö\n" :check-issued (lambda () t) :save t))
             (after (kargu-bridge-edit-document-change-after observation)))
        (should (eq (kargu-bridge-edit-document-change-stage observation) :save-returned))
        (should-not (kargu-bridge-edit-document-change-failure observation))
        (should (equal (kargu-bridge-edit-document-text after) "new ö\nhook 🦀\n"))
        (should-not (kargu-bridge-edit-document-dirty after))
        (should (> (kargu-bridge-edit-document-tick after)
                   (kargu-bridge-edit-document-change-write-tick observation)))
        (should (eq (kargu-bridge-edit-document-coding after) 'utf-8-dos))
        (should (equal (with-temp-buffer
                         (set-buffer-multibyte nil)
                         (insert-file-contents-literally file)
                         (buffer-string))
                       (encode-coding-string "new ö\r\nhook 🦀\r\n" 'utf-8-unix)))))))

(ert-deftest kargu-native-edit-document-failed-save-retains-foreign-disk-test ()
  (kargu-edit-document-test--with-file "old\n"
    (let ((snapshot (kargu-bridge-edit-document-capture buffer)))
      (cl-letf (((symbol-function 'save-buffer)
                 (lambda (&rest _)
                   (write-region "foreign\n" nil file nil 'silent)
                   (error "Save failed after external write"))))
        (let ((observation
               (kargu-bridge-edit-document-replace
                snapshot "new\n" :check-issued (lambda () t) :save t)))
          (should (eq (kargu-bridge-edit-document-change-stage observation) :saving))
          (should (kargu-bridge-edit-document-change-failure observation))
          (should (equal (kargu-bridge-edit-document-text
                          (kargu-bridge-edit-document-change-after observation)) "new\n"))
          (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string)) "foreign\n")))))))

(ert-deftest kargu-native-edit-document-change-hook-error-is-atomic-test ()
  (kargu-edit-document-test--with-file "old\n"
    (let ((snapshot (kargu-bridge-edit-document-capture buffer)))
      (add-hook 'after-change-functions (lambda (&rest _) (error "Hook failed")) nil t)
      (let ((observation
             (kargu-bridge-edit-document-replace
              snapshot "new\n" :check-issued (lambda () t) :save t)))
        (should (eq (kargu-bridge-edit-document-change-stage observation) :replacing))
        (should (kargu-bridge-edit-document-change-failure observation))
        (should (equal (buffer-string) "old\n"))
        (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string)) "old\n"))))))

(ert-deftest kargu-native-edit-document-empty-new-file-save-test ()
  (let* ((directory (make-temp-file "kargu-document-" t))
         (file (expand-file-name "new" directory))
         (buffer (find-file-noselect file)))
    (unwind-protect
        (let* ((snapshot (kargu-bridge-edit-document-capture buffer))
               (observation
                (kargu-bridge-edit-document-replace
                 snapshot "" :check-issued (lambda () t) :save t)))
          (should-not (kargu-bridge-edit-document-change-failure observation))
          (should (file-exists-p file))
          (should (= (file-attribute-size (file-attributes file)) 0)))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-directory directory t))))

(ert-deftest kargu-native-edit-document-post-save-observation-failure-is-explicit-test ()
  (kargu-edit-document-test--with-file "old\n"
    (let ((kargu-bridge-edit-document--text-bytes 64)
          (snapshot (kargu-bridge-edit-document-capture buffer)))
      (add-hook 'before-save-hook (lambda () (insert (make-string 65 ?x))) nil t)
      (let ((observation
             (kargu-bridge-edit-document-replace
              snapshot "new\n" :check-issued (lambda () t) :save t)))
        (should (eq (kargu-bridge-edit-document-change-stage observation) :save-returned))
        (should-not (kargu-bridge-edit-document-change-after observation))
        (should (eq (car (kargu-bridge-edit-document-change-observation-failure observation))
                    'kargu-bridge-edit-document-limit))
        (should (> (file-attribute-size (file-attributes file)) 64))))))

(ert-deftest kargu-native-edit-document-foreign-disk-during-change-hook-prevents-save-test ()
  (kargu-edit-document-test--with-file "old\n"
    (let ((snapshot (kargu-bridge-edit-document-capture buffer)))
      (add-hook 'after-change-functions
                (lambda (&rest _) (write-region "foreign\n" nil file nil 'silent)) nil t)
      (let ((observation
             (kargu-bridge-edit-document-replace
              snapshot "new\n" :check-issued (lambda () t) :save t)))
        (should (eq (kargu-bridge-edit-document-change-stage observation) :replaced))
        (should (kargu-bridge-edit-document-change-failure observation))
        (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string)) "foreign\n"))))))

(ert-deftest kargu-native-edit-document-copy-does-not-share-identity-test ()
  (kargu-edit-document-test--with-file "old\n"
    (let* ((original (kargu-bridge-edit-document-capture buffer))
           (copy (generate-new-buffer " *kargu-document-copy*")))
      (unwind-protect
          (with-current-buffer copy
            (setq buffer-file-name file
                  kargu-bridge-edit-document--id
                  (buffer-local-value 'kargu-bridge-edit-document--id buffer))
            (insert "old\n") (set-buffer-modified-p nil)
            (should-not (equal (kargu-bridge-edit-document-id original)
                               (kargu-bridge-edit-document-id
                                (kargu-bridge-edit-document-capture copy)))))
        (kill-buffer copy)))))

(ert-deftest kargu-native-edit-document-parent-link-redirect-is-stale-test ()
  (kargu-edit-document-test--with-file "old\n"
    (let* ((other (expand-file-name "other" directory))
           (link (expand-file-name "link" directory)))
      (make-directory other)
      (add-name-to-file file (expand-file-name "source" other))
      (make-symbolic-link directory link)
      (setq buffer-file-name (expand-file-name "source" link))
      (let ((snapshot (kargu-bridge-edit-document-capture buffer)))
        (delete-file link)
        (make-symbolic-link other link)
        ;; Both resolutions name the same inode with identical captured stat.
        (let ((change (kargu-bridge-edit-document-replace
                       snapshot "new\n" :check-issued (lambda () t) :save t)))
          (should (eq (kargu-bridge-edit-document-change-stage change) :not-entered))
          (should (kargu-bridge-edit-document-change-failure change))
          (should (equal (buffer-string) "old\n")))))))

(ert-deftest kargu-native-edit-document-revoke-during-replacement-prevents-save-test ()
  (kargu-edit-document-test--with-file "old\n"
    (let ((snapshot (kargu-bridge-edit-document-capture buffer)) (live t))
      (add-hook 'after-change-functions (lambda (&rest _) (setq live nil)) nil t)
      (let ((change (kargu-bridge-edit-document-replace
                     snapshot "new\n" :check-issued (lambda () live) :save t)))
        (should (eq (kargu-bridge-edit-document-change-stage change) :replaced))
        (should (eq (car (kargu-bridge-edit-document-change-failure change))
                    'kargu-bridge-edit-document-revoked))
        (should (equal (kargu-bridge-edit-document-text
                        (kargu-bridge-edit-document-change-after change)) "new\n"))
        (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string)) "old\n"))))))

(ert-deftest kargu-native-edit-document-killed-during-save-has-no-final-observation-test ()
  (kargu-edit-document-test--with-file "old\n"
    (let ((snapshot (kargu-bridge-edit-document-capture buffer)))
      (cl-letf (((symbol-function 'save-buffer)
                 (lambda (&rest _) (set-buffer-modified-p nil) (kill-buffer buffer))))
        (let ((change (kargu-bridge-edit-document-replace
                       snapshot "new\n" :check-issued (lambda () t) :save t)))
          (should (eq (kargu-bridge-edit-document-change-stage change) :save-returned))
          (should-not (kargu-bridge-edit-document-change-after change))
          (should (kargu-bridge-edit-document-change-observation-failure change)))))))

(ert-deftest kargu-native-edit-document-after-save-hook-error-reports-real-saved-state-test ()
  (kargu-edit-document-test--with-file "old\n"
    (let ((snapshot (kargu-bridge-edit-document-capture buffer)))
      (add-hook 'after-save-hook (lambda () (error "Post-save hook failed")) nil t)
      (let ((change (kargu-bridge-edit-document-replace
                     snapshot "new\n" :check-issued (lambda () t) :save t)))
        (should (eq (kargu-bridge-edit-document-change-stage change) :saving))
        (should (kargu-bridge-edit-document-change-failure change))
        (should-not (kargu-bridge-edit-document-dirty
                     (kargu-bridge-edit-document-change-after change)))
        (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string)) "new\n"))))))

(ert-deftest kargu-native-edit-document-readonly-text-outside-narrowing-rejects-entry-test ()
  (kargu-edit-document-test--with-file "old\n"
    (let ((snapshot (kargu-bridge-edit-document-capture buffer)))
      (put-text-property 1 2 'read-only t)
      (set-buffer-modified-p nil)
      (narrow-to-region 3 4)
      (should (kargu-bridge-edit-document-read-only
               (kargu-bridge-edit-document-capture buffer)))
      (let ((change (kargu-bridge-edit-document-replace
                     snapshot "new\n" :check-issued (lambda () t) :save t)))
        (should (eq (kargu-bridge-edit-document-change-stage change) :not-entered))
        (should (kargu-bridge-edit-document-change-failure change))))))

(ert-deftest kargu-native-edit-document-receipt-captures-actual-change-hook-text-test ()
  (kargu-edit-document-test--with-file "old\n"
    (let ((snapshot (kargu-bridge-edit-document-capture buffer)))
      (add-hook 'after-change-functions
                (lambda (&rest _) (goto-char (point-max)) (insert "hook\n")) nil t)
      (let ((change (kargu-bridge-edit-document-replace
                     snapshot "new\n" :check-issued (lambda () t))))
        (should-not (kargu-bridge-edit-document-change-failure change))
        (should (equal (kargu-bridge-edit-document-change-written change)
                       (kargu-bridge-edit-document-text
                        (kargu-bridge-edit-document-change-after change))))))))

(ert-deftest kargu-native-edit-document-delete-rechecks-after-guard-test ()
  (kargu-edit-document-test--with-file "old\n"
    (let* ((snapshot (kargu-bridge-edit-document-capture buffer))
           (change (kargu-bridge-edit-document-delete
                    snapshot :check-issued
                    (lambda () (write-region "foreign\n" nil file nil 'silent) t))))
      (should (eq (kargu-bridge-edit-document-change-stage change) :not-entered))
      (should (file-exists-p file))
      (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string)) "foreign\n")))))

(ert-deftest kargu-native-edit-document-delete-does-not-invent-buffer-closure-test ()
  (kargu-edit-document-test--with-file "old\n"
    (let ((snapshot (kargu-bridge-edit-document-capture buffer))
          (kill-buffer-query-functions (list (lambda () nil))))
      (let ((change (kargu-bridge-edit-document-delete snapshot :check-issued (lambda () t))))
        (should (buffer-live-p buffer))
        (should-not (file-exists-p file))
        (should (kargu-bridge-edit-document-p (kargu-bridge-edit-document-change-after change)))))))

(provide 'tests/test-native-edit-document)
;;; test-native-edit-document.el ends here
