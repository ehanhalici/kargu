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
       ;; Rust renders a bounded excerpt and reports its window.
       (should (string-search "(file big.txt, lines 1-50 of" out))
       (should (string-search "50 | 50" out))
       (should-not (string-search "51 | 51" out))))))

(ert-deftest kargu-attach-missing-file-says-not-found-test ()
  "An unknown mention is reported, not silently dropped."
  (kargu-attach-test--with-project '(("a.txt" . "x\n"))
                                   (let ((out (kargu-attach-test--expand "see @nope.txt")))
                                     (should (string-search "<code_selection path=\"nope.txt\">" out))
                                     (should-not (string-search "Called the Read tool" out)))))

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
           (should (string-search "<code_selection path=\"missing.txt\">" out))
           (should (= calls (1+ n)))))))))

(ert-deftest kargu-attach-unsaved-buffer-and-line-range-come-from-native-reads-test ()
  "Live unsaved text wins over disk, and a line mention reads only its window."
  (kargu-attach-test--with-project
   '(("a.txt" . "disk one\ndisk two\n") ("lines.txt" . "l1\nl2\nl3\nl4\n"))
   (let ((buffer (find-file-noselect (expand-file-name "a.txt" root))))
     (unwind-protect
         (progn
           (with-current-buffer buffer
             (erase-buffer) (insert "ram one\nram two\n"))
           (cl-letf (((symbol-function 'insert-file-contents)
                      (lambda (&rest _) (ert-fail "Attachment read the disk in Elisp"))))
             (let ((out (kargu-attach-test--expand "@a.txt and @line:lines.txt:2-3")))
               (should (string-search "ram two" out))
               (should-not (string-search "disk one" out))
               (should (string-search "2 | l2" out))
               (should (string-search "3 | l3" out))
               (should-not (string-search "4 | l4" out)))))
       (with-current-buffer buffer (set-buffer-modified-p nil))
       (kill-buffer buffer)))))

(ert-deftest kargu-attach-folder-and-git-mentions-are-native-test ()
  "Folder and Git targets attach Rust output; Emacs lists no directory itself."
  (kargu-test-with-git-repo '(("src/one.el" . "(one)\n") ("src/two.el" . "(two)\n")
                              ("README" . "base\n"))
    (write-region "changed\n" nil (expand-file-name "README" repo) nil 'silent)
    (write-region "staged\n" nil (expand-file-name "src/two.el" repo) nil 'silent)
    (call-process "git" nil nil nil "add" "src/two.el")
    (cl-letf (((symbol-function 'kargu-chat--completion-roots) (lambda () (list repo)))
              ((symbol-function 'directory-files)
               (lambda (&rest _) (ert-fail "Folder mention listed a directory in Elisp")))
              ((symbol-function 'directory-files-recursively)
               (lambda (&rest _) (ert-fail "Folder mention scanned recursively in Elisp"))))
      (let ((out (kargu-attach-test--expand "see @folder:src then @folder:src:2 and @git:diff and @git:staged")))
        (should (string-search "<attached_folder path=\"src\">" out))
        (should (string-search "one.el" out))
        (should (string-search "two.el" out))
        (should (string-search "<attached_folder path=\"src:2\">" out))
        (should (string-search "<attached_git target=\"git:diff\">" out))
        (should (string-search "+changed" out))
        (should (string-search "<attached_git target=\"git:staged\">" out))
        (should (string-search "+staged" out))))))

(ert-deftest kargu-attach-buffer-mentions-respect-grants-and-isolate-boundaries-test ()
  "Buffer mentions require explicit grants for fileless/out-of-root and reject TRAMP/archives."
  (let ((scratch (get-buffer-create "*test-kargu-scratch*"))
        (hidden (get-buffer-create " *test-kargu-hidden*"))
        (archive (get-buffer-create "archive.tar:member.txt"))
        (tramp (get-buffer-create "*test-kargu-tramp*")))
    (unwind-protect
        (progn
          (with-current-buffer scratch
            (erase-buffer) (insert "scratch content\n"))
          (with-current-buffer hidden
            (erase-buffer) (insert "secret hidden\n"))
          (with-current-buffer archive
            (erase-buffer) (insert "archive text\n"))
          (with-current-buffer tramp
            (setq-local buffer-file-name "/ssh:remote.host:/tmp/remote.txt")
            (erase-buffer) (insert "remote secret\n"))
          ;; 1. Missing buffer says not found
          (let ((out (kargu-attach-test--expand "see @buff:nonexistent")))
            (should (string-search "<code_selection path=\"nonexistent\">" out))
            (should (string-search "(buffer not found)" out)))
          ;; 2. Hidden buffer is rejected
          (let ((out (kargu-attach-test--expand "see @buff:\" *test-kargu-hidden*\"")))
            (should (string-search "(hidden buffers cannot be attached)" out)))
          ;; 3. Foreign archive buffer is rejected
          (let ((out (kargu-attach-test--expand "see @buff:archive.tar:member.txt")))
            (should (string-search "(foreign archive buffers are unavailable)" out)))
          ;; 4. Fileless buffer without grant is rejected
          (let ((kargu-chat-buffer-grants nil))
            (let ((out (kargu-attach-test--expand "see @buff:*test-kargu-scratch*")))
              (should (string-search "(fileless buffer requires explicit grant)" out))
              (should-not (string-search "scratch content" out))))
          ;; 5. Fileless buffer with explicit grant succeeds
          (let ((kargu-chat-buffer-grants '("*test-kargu-scratch*")))
            (let ((out (kargu-attach-test--expand "see @buff:*test-kargu-scratch*")))
              (should (string-search "<attached_buffer name=\"*test-kargu-scratch*\">" out))
              (should (string-search "scratch content" out))))
          ;; 6. Simulated remote TRAMP buffer is rejected without fallback
          (let ((out (kargu-attach-test--expand "see @buff:*test-kargu-tramp*")))
            (should (string-search "(remote TRAMP buffers are unavailable)" out))))
      (kill-buffer scratch)
      (kill-buffer hidden)
      (kill-buffer archive)
      (kill-buffer tramp))))

(provide 'tests/test-attach)
;;; test-attach.el ends here
