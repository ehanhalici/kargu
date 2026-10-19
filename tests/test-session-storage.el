;;; test-session-storage.el --- Session storage regressions -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Explicit storage policy, non-destructive import and bounded atomic writes.

;;; Code:

(require 'ert)
(require 'tests/test-helpers)
(require 'kargu/chat/session/storage)

(ert-deftest kargu-session-storage-central-default-and-local-opt-in-test ()
  "An existing local directory never opts a project into local storage."
  (kargu-test-with-git-repo nil
    (let* ((kargu-sessions-directory (expand-file-name "central" repo))
           (kargu-session-storage-location 'central)
           (local (expand-file-name ".kargu/sessions/" repo))
           (exclude (expand-file-name ".git/info/exclude" repo))
           (exclude-before (with-temp-buffer
                             (insert-file-contents exclude) (buffer-string)))
           (data '(("id" . "safe") ("transcript" . "ğ — private"))))
      (make-directory local t)
      (let ((file (kargu-session-storage-write "safe" repo data)))
        (should (kargu-permission-within-project-p file kargu-sessions-directory))
        (should-not (file-exists-p (expand-file-name "safe.json" local)))
        (should (equal (kargu-aget (kargu-session-storage-read "safe" repo) "transcript")
                       "ğ — private")))
      (let ((kargu-session-storage-location 'project))
        (should (equal (kargu-session-storage-write "safe" repo data)
                       (expand-file-name "safe.json" local))))
      (should-not (file-exists-p (expand-file-name ".gitignore" repo)))
      (should (equal exclude-before (with-temp-buffer
                                     (insert-file-contents exclude) (buffer-string)))))))

(ert-deftest kargu-session-storage-import-retains-source-and-refuses-collision-test ()
  "Import copies only the requested project record and never replaces a record."
  (kargu-test-with-git-repo nil
    (let* ((kargu-sessions-directory (expand-file-name "central" repo))
           (kargu-session-storage-location 'project)
           (source (kargu-session-storage-write
                    "safe" repo '(("id" . "safe") ("messages" . [])))))
      (let ((target (kargu-session-storage-import-local "safe" repo)))
        (should (file-exists-p source))
        (should (file-exists-p target))
        (should-not (equal source target))
        (should-error (kargu-session-storage-import-local "safe" repo)
                      :type 'file-already-exists)
        (let ((kargu-session-storage-location 'central))
          (should (equal (kargu-aget (kargu-session-storage-read "safe" repo) "id") "safe"))
          (let ((other (expand-file-name "other-project" repo)))
            (make-directory other)
            (should-not (kargu-session-storage-read "safe" other)))))
      (should (equal (kargu-session-storage-local-ids repo) '("safe"))))))

(ert-deftest kargu-session-storage-import-rejects-mismatched-id-and-links-test ()
  "Import refuses misleading metadata and paths outside the local boundary."
  (kargu-test-with-git-repo nil
    (let* ((kargu-sessions-directory (expand-file-name "central" repo))
           (kargu-session-storage-location 'project)
           (source (kargu-session-storage-write "safe" repo '(("id" . "other")))))
      (should-error (kargu-session-storage-import-local "safe" repo) :type 'user-error)
      (should-not (file-exists-p kargu-sessions-directory))
      (copy-file source (expand-file-name ".kargu/linked.json" repo))
      (make-symbolic-link (expand-file-name ".kargu/linked.json" repo)
                          (expand-file-name ".kargu/sessions/linked.json" repo))
      (should-error (kargu-session-storage-import-local "linked" repo) :type 'user-error)
      (should (equal (kargu-session-storage-local-ids repo) '("safe"))))))

(ert-deftest kargu-session-storage-bounded-read-and-write-test ()
  "Oversized records and malformed JSON are rejected without replacing files."
  (kargu-test-with-git-repo nil
    (let* ((kargu-sessions-directory (expand-file-name "central" repo))
           (kargu-session-storage-location 'central)
           (file (kargu-session-storage-write "safe" repo '(("id" . "safe")))))
      (let ((kargu-session-max-file-bytes 4))
        (should-error (kargu-session-storage-read "safe" repo) :type 'user-error)
        (should-error (kargu-session-storage-write "safe" repo '(("id" . "replacement")))
                      :type 'user-error))
      (should (equal (kargu-aget (kargu-session-storage-read "safe" repo) "id") "safe"))
      (write-region "{} {}" nil file)
      (should-error (kargu-session-storage-read "safe" repo) :type 'user-error))))

(ert-deftest kargu-session-storage-growth-read-stays-bounded-test ()
  "A file growing after stat is read only up to the byte limit plus one."
  (kargu-test-with-git-repo nil
    (let* ((kargu-sessions-directory (expand-file-name "central" repo))
           (kargu-session-storage-location 'central)
           (file (kargu-session-storage-write "safe" repo '(("id" . "safe"))))
           (kargu-session-max-file-bytes 32)
           (reader (symbol-function 'insert-file-contents-literally))
           observed-end)
      (cl-letf (((symbol-function 'insert-file-contents-literally)
                 (lambda (path visit begin end &rest args)
                   (setq observed-end end)
                   (write-region (make-string 128 ?x) nil file)
                   (apply reader path visit begin end args))))
        (should-error (kargu-session-storage-read "safe" repo) :type 'user-error))
      (should (= observed-end 33)))))

(ert-deftest kargu-session-storage-failed-publication-retains-record-test ()
  "Rename failure preserves the old record and removes the private temporary."
  (kargu-test-with-git-repo nil
    (let* ((kargu-sessions-directory (expand-file-name "central" repo))
           (kargu-session-storage-location 'central)
           (file (kargu-session-storage-write "safe" repo '(("id" . "safe")))))
      (cl-letf (((symbol-function 'rename-file)
                 (lambda (&rest _) (signal 'file-error '("simulated publication failure")))))
        (should-error (kargu-session-storage-write "safe" repo '(("id" . "replacement")))
                      :type 'file-error))
      (should (equal (kargu-aget (kargu-session-storage-read "safe" repo) "id") "safe"))
      (should (equal (directory-files (file-name-directory file) nil "^[^.]")
                     '("safe.json")))
      (should-not (directory-files (file-name-directory file) nil "^\\.kargu-session-"))
      (should (= (logand (file-modes file) #o777) #o600)))))

(provide 'tests/test-session-storage)
;;; test-session-storage.el ends here
