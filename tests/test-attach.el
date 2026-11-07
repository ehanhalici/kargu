;;; test-attach.el --- Tests for @mention attachments -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Mention spans come from the real native lexer; only attachment rendering
;; and input-buffer completion stay in Emacs.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'tests/test-helpers)
(require 'kargu/core)
(require 'kargu/chat)
(require 'kargu/chat/attach)
(require 'kargu/chat/complete)
(require 'kargu/permission/guards)

(defun kargu-attach-test--spans (prompt)
  "Return the real native lexer's spans for PROMPT."
  (let ((reply (kargu-test-await
                (lambda (done)
                  (kargu-bridge-mentions-parse prompt (lambda (spans failure) (funcall done (or spans failure))))))))
    (should (vectorp reply))
    reply))

(defun kargu-attach-test--mentions (prompt)
  "Return PROMPT's native file and symbol mentions as (FILES . SYMBOLS)."
  (kargu-chat--span-mentions (kargu-attach-test--spans prompt)))

(defun kargu-attach-test--expand (prompt)
  "Expand PROMPT through the async native path and return the text."
  (let ((reply (kargu-test-await
                (lambda (done)
                  (kargu-chat--expand-prompt prompt (lambda (text failure) (funcall done (or text failure))))))))
    (should (stringp reply))
    reply))

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
  "Native spans exclude quotes and sentence punctuation; symbols stay separate."
  (should (equal (kargu-attach-test--mentions "see @src/a.el, and (@\"b.py\"). also @`c.go`.")
                 '(("src/a.el" "b.py" "c.go"))))
  (should (equal (kargu-attach-test--mentions "@plain word and @a.el::foo")
                 '(nil "a.el::foo"))))

(ert-deftest kargu-attach-native-spans-keep-literals-and-unicode-paths-test ()
  "Fenced code stays literal and a quoted Unicode path is one byte-exact span."
  (let* ((prompt "🦀 @\"dir with space/ü.txt\" and ```@fenced.rs```")
         (spans (kargu-attach-test--spans prompt))
         (span (aref spans 0)))
    (should (= (length spans) 1))
    (should (equal (gethash "path" (gethash "target" span)) "dir with space/ü.txt"))
    ;; Native coordinates are UTF-8 bytes; the crab emoji is four bytes.
    (should (= (gethash "start" span) 5))
    (should (equal (gethash "raw" span)
                   (decode-coding-string
                    (substring (encode-coding-string prompt 'utf-8)
                               (gethash "start" span) (gethash "end" span))
                    'utf-8)))))

(ert-deftest kargu-attach-short-file-is-inlined-with-line-numbers-test ()
  "A short file becomes a synthetic Read transcript."
  (kargu-attach-test--with-project '(("a.txt" . "one\ntwo\n"))
                                   (let ((out (kargu-attach-test--expand "look at @a.txt")))
                                     (should (string-prefix-p "<user_query>\nlook at @a.txt\n</user_query>" out))
                                     (should (string-search "Called the Read tool with" out))
                                     (should (string-search "two" out))
                                     (should (string-search "<attached_files>" out)))))

(ert-deftest kargu-attach-long-file-is-referenced-not-inlined-test ()
  "A file over the line limit is referenced so the model reads it on demand."
  (kargu-attach-test--with-project
   (list (cons "big.txt" (mapconcat #'number-to-string (number-sequence 1 400) "\n")))
   (let ((kargu-chat-attach-max-lines 50))
     (let ((out (kargu-attach-test--expand "read @big.txt")))
       (should (string-search "<referenced_file" out))
       (should-not (string-search "\n399\n" out))))))

(ert-deftest kargu-attach-missing-file-says-not-found-test ()
  "An unknown mention is reported, not silently dropped."
  (kargu-attach-test--with-project '(("a.txt" . "x\n"))
                                   (should (string-search "(not found)" (kargu-attach-test--expand "see @nope.txt")))))

(ert-deftest kargu-attach-refuses-paths-outside-the-project-test ()
  "A mention that climbs out of the project is not attached."
  (kargu-attach-test--with-project '(("a.txt" . "x\n"))
                                   (let ((outside (make-temp-file "kargu-outside-")))
                                     (unwind-protect
                                         (progn
                                           (write-region "secret\n" nil outside nil 'silent)
                                           (should-not (string-search
                                                        "secret"
                                                        (kargu-attach-test--expand
                                                         (format "see @../%s" (file-name-nondirectory outside))))))
                                       (delete-file outside)))))

(ert-deftest kargu-attach-prompt-without-mentions-is-only-the-query-test ()
  "No mention means no attachment block."
  (should (equal (kargu-attach-test--expand "hello")
                 "<user_query>\nhello\n</user_query>")))

(ert-deftest kargu-attach-python-symbol-stops-before-sibling-method-test ()
  "An indented Python method excludes its sibling and preserves point."
  (with-temp-buffer
    (insert "class C:\n    def first(self):\n        return {\"x\": 1}\n\n    def second(self):\n        return 2\n")
    (python-mode)
    (goto-char (point-min))
    (search-forward "def first")
    (let ((found (- (point) (length "def first")))
          (saved (point)))
      (should (equal (kargu-chat--compute-symbol-bounds found) '(2 . 3)))
      (should (= (point) saved)))))

(ert-deftest kargu-attach-email-addresses-are-not-mentions-test ()
  "Email addresses and package handles do not trigger file attachments."
  (should (equal (kargu-attach-test--mentions
                  "user@domain.com, <other+tag@firma.com> pkg@1.2 @a.el (@b.py)")
                 '(("a.el" "b.py"))))
  (let ((prompt "Write to user@domain.com"))
    (cl-letf (((symbol-function 'kargu-chat--completion-roots)
               (lambda () (ert-fail "Email must not scan project roots"))))
      (should (equal (kargu-attach-test--expand prompt)
                     (format "<user_query>\n%s\n</user_query>" prompt))))))

(ert-deftest kargu-attach-symbol-search-preserves-editor-state-test ()
  "Each language search starts independently and preserves point and matches."
  (dolist (source '("(defun target () t)\n" "fn target() {}\n"
                    "func target() {}\n" "function target() {}\n"
                    "def target():\n    pass\n" "class target {}\n"
                    "struct target {}\n" "target = 1\n"))
    (with-temp-buffer
      (insert source)
      (goto-char (point-max))
      (string-match "saved" "saved")
      (let ((saved-point (point)) (saved-match (match-data)))
        (let ((found (kargu-chat--find-symbol-pos "target")))
          (should (numberp found))
          (should (= (line-number-at-pos found) 1)))
        (should (= (point) saved-point))
        (should (equal (match-data) saved-match))
        (should-not (kargu-chat--find-symbol-pos "not_here"))
        (should (= (point) saved-point))))))

(ert-deftest kargu-attach-expansion-collects-roots-once-test ()
  "Mixed file and symbol mentions reuse roots for this expansion only."
  (kargu-attach-test--with-project
   '(("a.el" . "(defun target () t)\n") ("b.txt" . "second file\n"))
   (let ((calls 0))
     (cl-letf (((symbol-function 'kargu-chat--completion-roots)
                (lambda () (cl-incf calls) (list root))))
       (dotimes (n 2)
         (let ((out (kargu-attach-test--expand
                     "@a.el @b.txt @a.el::target @missing.txt")))
           (should (string-search "second file" out))
           (should (string-search "symbol target" out))
           (should (string-search "(not found)" out))
           (should (= calls (1+ n)))))))))

(provide 'tests/test-attach)
;;; test-attach.el ends here
