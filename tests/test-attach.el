;;; tests/test-attach.el --- Tests for @mention attachments -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'ert)
(require 'cl-lib)
(require 'tests/test-helpers)
(require 'kargu/core)
(require 'kargu/chat)
(require 'kargu/chat/attach)
(require 'kargu/chat/complete)
(require 'kargu/permission/guards)

(defmacro kargu-attach-test--with-project (files &rest body)
  "Run BODY in a temp project holding FILES, an alist of (NAME . TEXT).
`root' is bound to the project directory."
  (declare (indent 1))
  `(let* ((root (file-name-as-directory (make-temp-file "kargu-attach-" t)))
          (kargu-permission--override-root root))
     (unwind-protect
         (progn
           (dolist (f ,files)
             (let ((path (expand-file-name (car f) root)))
               (make-directory (file-name-directory path) t)
               (write-region (cdr f) nil path nil 'silent)))
           (cl-letf (((symbol-function 'kargu-chat--completion-roots)
                      (lambda () (list root))))
             ,@body))
       (delete-directory root t))))

(ert-deftest kargu-attach-mention-tokens-are-cleaned-test ()
  "Brackets, quotes and trailing punctuation are not part of a mention."
  (should (equal (kargu-chat--at-tokens "see @src/a.el, and (@\"b.py\"). also @`c.go`.")
                 '("src/a.el" "b.py" "c.go")))
  (should (kargu-chat--file-mention-p "src/a.el"))
  (should-not (kargu-chat--file-mention-p "plain"))
  (should (kargu-chat--symbol-mention-p "a.el::foo"))
  (should-not (kargu-chat--file-mention-p "a.el::foo")))

(ert-deftest kargu-attach-short-file-is-inlined-with-line-numbers-test ()
  "A short file becomes a synthetic Read transcript."
  (kargu-attach-test--with-project '(("a.txt" . "one\ntwo\n"))
    (let ((out (kargu-chat--expand-prompt "look at @a.txt")))
      (should (string-prefix-p "<user_query>\nlook at @a.txt\n</user_query>" out))
      (should (string-search "Called the Read tool with" out))
      (should (string-search "two" out))
      (should (string-search "<attached_files>" out)))))

(ert-deftest kargu-attach-long-file-is-referenced-not-inlined-test ()
  "A file over the line limit is referenced so the model reads it on demand."
  (kargu-attach-test--with-project
      (list (cons "big.txt" (mapconcat #'number-to-string (number-sequence 1 400) "\n")))
    (let ((kargu-chat-attach-max-lines 50))
      (let ((out (kargu-chat--expand-prompt "read @big.txt")))
        (should (string-search "<referenced_file" out))
        (should-not (string-search "\n399\n" out))))))

(ert-deftest kargu-attach-missing-file-says-not-found-test ()
  "An unknown mention is reported, not silently dropped."
  (kargu-attach-test--with-project '(("a.txt" . "x\n"))
    (should (string-search "(not found)" (kargu-chat--expand-prompt "see @nope.txt")))))

(ert-deftest kargu-attach-refuses-paths-outside-the-project-test ()
  "A mention that climbs out of the project is not attached."
  (kargu-attach-test--with-project '(("a.txt" . "x\n"))
    (let ((outside (make-temp-file "kargu-outside-")))
      (unwind-protect
          (progn
            (write-region "secret\n" nil outside nil 'silent)
            (should-not (string-search
                         "secret"
                         (kargu-chat--expand-prompt
                          (format "see @../%s" (file-name-nondirectory outside))))))
        (delete-file outside)))))

(ert-deftest kargu-attach-prompt-without-mentions-is-only-the-query-test ()
  "No mention means no attachment block."
  (should (equal (kargu-chat--expand-prompt "hello")
                 "<user_query>\nhello\n</user_query>")))

(provide 'tests/test-attach)
;;; test-attach.el ends here
