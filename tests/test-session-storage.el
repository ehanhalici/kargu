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
                             (insert-file-contents exclude) (buffer-string))))
      (make-directory local t)
      (let ((file (kargu-session-storage-file "safe" repo)))
        (should (kargu-permission-within-project-p file kargu-sessions-directory))
        (should-not (string-prefix-p local file)))
      (let ((kargu-session-storage-location 'project))
        (should (equal (kargu-session-storage-file "safe" repo)
                       (expand-file-name "safe.json" local))))
      (should-not (file-exists-p (expand-file-name ".gitignore" repo)))
      (should (equal exclude-before (with-temp-buffer
                                     (insert-file-contents exclude) (buffer-string)))))))

(provide 'tests/test-session-storage)
;;; test-session-storage.el ends here
