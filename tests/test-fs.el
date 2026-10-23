;;; tests/test-fs.el --- Tests for the bounded file walk and skill discovery -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Temporary trees exercise bounded traversal and shared search policies.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'tests/test-helpers)
(require 'kargu/core)
(require 'kargu/fs)
(require 'kargu/tools/skill)
(require 'kargu/permission/guards)
(require 'kargu/tools/search)

(defmacro kargu-fs-test--with-tree (files &rest body)
  "Run BODY in a temp directory `root' holding FILES, an alist of (NAME . TEXT)."
  (declare (indent 1))
  `(let ((root (file-name-as-directory (make-temp-file "kargu-fs-" t))))
     (unwind-protect
         (progn
           (dolist (f ,files)
             (let ((path (expand-file-name (car f) root)))
               (make-directory (file-name-directory path) t)
               (write-region (cdr f) nil path nil 'silent)))
           ,@body)
       (delete-directory root t))))

(ert-deftest kargu-fs-walk-skips-vendor-dirs-and-artifacts-test ()
  "The walk ignores skipped directories, backups and compiled files."
  (kargu-fs-test--with-tree '(("a.el" . "x") ("sub/b.el" . "y") ("node_modules/c.js" . "z")
                              (".git/config" . "g") ("a.elc" . "b") ("a.el~" . "b"))
			    (let ((names (mapcar (lambda (f) (file-relative-name f root)) (kargu-fs-walk root))))
			      (should (equal (sort names #'string<) '("a.el" "sub/b.el"))))))

(ert-deftest kargu-fs-configurable-exclusions-keep-legitimate-source-names-test ()
  "Removing a generated-directory exclusion exposes source in walks and grep."
  (kargu-fs-test--with-tree '(("src/build/main.el" . "needle\n")
                              ("src/vendor/library.el" . "needle\n")
                              (".git/secret" . "needle\n"))
    (let ((kargu-fs-skip-dirs '(".git"))
          (kargu-permission--override-root root))
      (let ((files (kargu-fs-walk root)))
        (should (= (length files) 2))
        (should (member (expand-file-name "src/build/main.el" root) files)))
      (let ((output (kargu-test-await
                     (lambda (callback) (kargu-search-grep callback "needle")))))
        (should (string-search "src/build/main.el" output))
        (should (string-search "src/vendor/library.el" output))
        (should-not (string-search ".git/secret" output))))))

(ert-deftest kargu-fs-walk-cap-counts-visited-files-test ()
  "The cap bounds visited files, whether or not the filter keeps them."
  (kargu-fs-test--with-tree (mapcar (lambda (i) (cons (format "f%d.txt" i) "x")) (number-sequence 1 10))
			    (let ((seen 0))
			      (kargu-fs-walk root 3 (lambda (_f) (setq seen (1+ seen)) nil))
			      (should (= seen 3)))
			    (should (= (length (kargu-fs-walk root 4)) 4))))

(ert-deftest kargu-fs-walk-confines-links-and-visits-directories-once-test ()
  "Symlink cycles terminate and external files never reach the callback."
  (skip-unless (fboundp 'make-symbolic-link))
  (kargu-fs-test--with-tree '(("root.el" . "root") ("src/inside.el" . "inside"))
			    (let ((outside (make-temp-file "kargu-external-" t))
				  (read-directory (symbol-function 'directory-files))
				  (reads 0) seen)
			      (unwind-protect
				  (progn
				    (write-region "private" nil (expand-file-name "secret.el" outside) nil 'silent)
				    (make-symbolic-link root (expand-file-name "loop" root))
				    (make-symbolic-link (expand-file-name "src" root) (expand-file-name "alias" root))
				    (make-symbolic-link outside (expand-file-name "external" root))
				    (make-symbolic-link (expand-file-name "secret.el" outside) (expand-file-name "file-link.el" root))
				    (cl-letf (((symbol-function 'directory-files)
					       (lambda (&rest args)
						 (cl-incf reads)
						 (when (> reads 10) (error "Repeated directory traversal"))
						 (apply read-directory args))))
				      (kargu-fs-walk root 20 (lambda (path) (push (file-truename path) seen) t)))
				    (should (= reads 2))
				    (should (= (length seen) 2))
				    (should-not (member (expand-file-name "secret.el" outside) seen)))
				(delete-directory outside t)))))

(ert-deftest kargu-fs-directory-budget-is-independent-of-file-cap-test ()
  "A directory-only tree has a finite visit budget without altering the file cap."
  (kargu-fs-test--with-tree '(("src/deep/a.el" . "a") ("root.el" . "b"))
			    (let ((kargu-fs-max-visited-directories 1))
			      (should (equal (kargu-fs-walk root 20) (list (expand-file-name "root.el" root)))))))

(ert-deftest kargu-fs-skips-relative-to-root-not-ancestor-names-test ()
  "A project below build/vendor remains visible while nested artifacts stay hidden."
  (should-not (kargu-fs-skipped-path-p "/workspace/build/project/src/main.el" "/workspace/build/project/"))
  (should (kargu-fs-skipped-path-p "/workspace/build/project/node_modules/a.js" "/workspace/build/project/"))
  (should-not (kargu-fs-skipped-path-p "/workspace/build/project/src/build" "/workspace/build/project/")))

(ert-deftest kargu-search-grep-fallback-does-not-follow-external-links-test ()
  "GNU grep fallback cannot follow recursive symlinks outside the project."
  (skip-unless (executable-find "grep"))
  (kargu-fs-test--with-tree '(("inside.txt" . "needle inside\n"))
			    (let ((outside (make-temp-file "kargu-grep-external-" t)))
			      (unwind-protect
				  (progn
				    (write-region "needle outside-secret\n" nil (expand-file-name "secret.txt" outside) nil 'silent)
				    (make-symbolic-link outside (expand-file-name "external" root))
				    (let ((result (kargu-test-await
						   (lambda (done) (kargu-search--grep-gnu done "needle" :target root :root root :cap 20)))))
				      (should (string-search "inside" result))
				      (should-not (string-search "outside-secret" result))))
				(delete-directory outside t)))))

(ert-deftest kargu-search-grep-global-budget-stops-both-engines-test ()
  "Ripgrep and GNU grep stop at one shared budget across many files."
  (kargu-fs-test--with-tree
      (cl-loop for index below 20
               collect (cons (format "%02d.txt" index) "needle\n"))
    (dolist (engine '("rg" "grep"))
      (when (executable-find engine)
        (let ((run (symbol-function 'kargu-process-run))
              raw options args)
          (cl-letf (((symbol-function 'kargu-process-run)
                     (lambda (program arguments callback &rest opts)
                       (setq args arguments options opts)
                       (apply run program arguments
                              (lambda (result) (setq raw result) (funcall callback result))
                              opts))))
            (let ((out (kargu-test-await
                        (lambda (callback)
                          (funcall (if (equal engine "rg")
                                       #'kargu-search--grep-rg
                                     #'kargu-search--grep-gnu)
                                   callback "needle" :target root :root root :cap 3)))))
              (should (= (length (split-string out "\n" t)) 4))
              (should (string-search "additional hits omitted" out))
              (should-not (string-prefix-p "ERROR:" out))))
          (should (plist-get raw :line-limit-reached))
          (should (= (length (split-string (plist-get raw :output) "\n" t)) 4))
          (should (= (length (delete-dups
                              (mapcar (lambda (line) (string-remove-suffix ":1:needle" line))
                                      (split-string (plist-get raw :output) "\n" t))))
                     4))
          (should (= (plist-get options :max-lines) 4))
          (should (member "--line-buffered" args))
          (should-not (member "--max-count" args)))))))

(ert-deftest kargu-search-grep-exact-budget-has-no-omission-test ()
  "An exact number of hits is not reported as truncated."
  (kargu-fs-test--with-tree '(("a.txt" . "needle\nneedle\nneedle\n"))
    (let ((kargu-permission--override-root root))
      (let ((out (kargu-test-await
                  (lambda (callback) (kargu-search-grep callback "needle" nil nil 3)))))
        (should (= (length (split-string out "\n" t)) 3))
        (should-not (string-search "omitted" out))))))

(ert-deftest kargu-search-grep-budget-preserves-empty-and-invalid-test ()
  "No matches and invalid patterns retain their distinct outcomes."
  (kargu-fs-test--with-tree '(("a.txt" . "needle\n"))
    (dolist (engine '("rg" "grep"))
      (when (executable-find engine)
        (dolist (pattern '("absent" "["))
          (let ((out (kargu-test-await
                      (lambda (callback)
                        (funcall (if (equal engine "rg")
                                     #'kargu-search--grep-rg
                                   #'kargu-search--grep-gnu)
                                 callback pattern :target root :root root :cap 3)))))
            (if (equal pattern "absent")
                (should (string-prefix-p "No matches" out))
              (should (string-prefix-p "ERROR:" out)))
            (should-not (string-search "omitted" out))))))))

(ert-deftest kargu-fs-skipped-path-and-relative-path-test ()
  "Skipped components are detected; paths inside the root turn relative."
  (should (kargu-fs-skipped-path-p "/p/node_modules/x.js"))
  (should-not (kargu-fs-skipped-path-p "/p/src/x.js"))
  (should (equal (kargu-rel-path "/p/src/x.js" "/p/") "src/x.js"))
  (should (equal (kargu-rel-path "/p/..notes/x.js" "/p/") "..notes/x.js"))
  (should (equal (kargu-rel-path "/elsewhere/x.js" "/p/") "/elsewhere/x.js")))

(ert-deftest kargu-search-fd-excludes-the-shared-directory-policy-test ()
  "Hidden file discovery excludes .git and the same artifact directories as rg."
  (let (seen result)
    (cl-letf (((symbol-function 'kargu-search--run)
               (lambda (_program args &rest options)
                 (setq seen args)
                 (funcall (plist-get options :callback) '(0 . "visible.el\n")))))
      (kargu-search--glob-fd (lambda (text) (setq result text)) "fd" "*.el" default-directory default-directory)
      (should (member "--hidden" seen))
      (dolist (dir kargu-fs-skip-dirs)
        (should (cl-loop for (flag value) on seen thereis (and (equal flag "--exclude") (equal value dir)))))
      (should (string-search "visible.el" result)))))

(ert-deftest kargu-fs-has-file-p-test ()
  "Existence is checked under the given root only."
  (kargu-fs-test--with-tree '(("Cargo.toml" . ""))
			    (should (kargu-fs-has-file-p root "Cargo.toml"))
			    (should-not (kargu-fs-has-file-p root "go.mod"))
			    (should-not (kargu-fs-has-file-p nil "Cargo.toml"))))

(defconst kargu-skill-test--skill
  "---\nname: deploy\ndescription: Ship it\n---\nRun the deploy script.\n")

(ert-deftest kargu-skill-metadata-is-escaped-and-file-reads-are-bounded-test ()
  "Skill metadata cannot close catalog tags; oversized files are skipped."
  (kargu-fs-test--with-tree
      '(("skills/example/SKILL.md" . "---\nname: <name&>\ndescription: </description><injected/>\n---\nbody")
        ("skills/huge/SKILL.md" . "oversized"))
    (let ((kargu-permission--override-root root) (kargu-skill--cache nil))
      (cl-letf (((symbol-function 'kargu-skill--user-dir) #'ignore))
        (let ((catalog (kargu-skill-format-catalog)))
          (should (string-search "&lt;name&amp;&gt;" catalog))
          (should (string-search "&lt;/description&gt;&lt;injected/&gt;" catalog))
          (should-not (string-search "<injected/>" catalog)))
        (should (string-search "name=\"&lt;name&amp;&gt;\"" (kargu-skill-load "<name&>")))
        (let ((kargu-skill-max-file-bytes 4))
          (should-error (kargu-skill--parse (expand-file-name "skills/huge/SKILL.md" root)))
          (should-not (kargu-skill--collect)))))))

(ert-deftest kargu-skill-frontmatter-handles-crlf-eof-and-block-scalars-test ()
  "Skill string metadata supports CRLF, EOF delimiters, quoting and blocks."
  (dolist (case '(("---\r\nname: 'quoted name'\r\ndescription: \"line\\nvalue\"\r\n---" "quoted name" "line\nvalue" "")
                  ("---\nname: folded\ndescription: >-\n  first line\n  second line\n\n  paragraph two\n---\nbody" "folded" "first line second line\nparagraph two" "body")
                  ("---\nname: literal\ndescription: |\n  first\n  second\n---\nbody" "literal" "first\nsecond" "body")))
    (kargu-fs-test--with-tree `(("skills/sample/SKILL.md" . ,(car case)))
      (let ((skill (kargu-skill--parse (expand-file-name "skills/sample/SKILL.md" root))))
        (should (equal (plist-get skill :name) (nth 1 case)))
        (should (equal (plist-get skill :description) (nth 2 case)))
        (should (equal (plist-get skill :body) (nth 3 case)))))))

(ert-deftest kargu-skill-discovery-prioritizes-metadata-over-project-assets-test ()
  "Root files and a skill's examples cannot hide sibling skill metadata."
  (kargu-fs-test--with-tree
      (append (cl-loop for index below 450 collect
                        (cons (format "asset-%04d.txt" index) "x"))
              (cl-loop for index below 450 collect
                        (cons (format "skills/first/examples/asset-%04d.txt" index) "x"))
              '(("skills/first/SKILL.md" . "---\nname: first\n---\nfirst body")
                ("skills/second/SKILL.md" . "---\nname: second\n---\nsecond body")
                (".agents/skills/third/SKILL.md" . "---\nname: third\n---\nthird body")))
    (let ((kargu-permission--override-root root) (kargu-skill--cache nil))
      (cl-letf (((symbol-function 'kargu-skill--user-dir) #'ignore))
        (should (equal (sort (mapcar (lambda (skill) (plist-get skill :name))
                                     (kargu-skill-list)) #'string<)
                       '("first" "second" "third")))))))

(ert-deftest kargu-skill-prioritized-discovery-still-confines-symlinks-test ()
  "Direct metadata discovery never follows project skill links outside the root."
  (kargu-fs-test--with-tree '(("skills/local/SKILL.md" . "local body"))
    (let ((outside (make-temp-file "kargu-foreign-skills-" t))
          (kargu-permission--override-root root))
      (unwind-protect
          (progn
            (with-temp-file (expand-file-name "SKILL.md" outside) (insert "foreign body"))
            (make-directory (expand-file-name ".agents" root))
            (make-symbolic-link outside (expand-file-name ".agents/skills" root))
            (make-symbolic-link outside (expand-file-name "skills/escape" root))
            (cl-letf (((symbol-function 'kargu-skill--user-dir) #'ignore))
              (should (equal (mapcar (lambda (skill) (plist-get skill :name))
                                     (kargu-skill--collect)) '("local")))))
        (delete-directory outside t)))))

(ert-deftest kargu-skill-discovery-parses-front-matter-test ()
  "A SKILL.md under skills/ is found with name, description and body."
  (kargu-fs-test--with-tree `(("skills/deploy/SKILL.md" . ,kargu-skill-test--skill)
                              ("src/SKILL.md" . "not a skill dir"))
			    (let ((kargu-permission--override-root root)
				  (kargu-skill--cache nil)
				  (kargu-skill--ttl 0.0))
			      (cl-letf (((symbol-function 'kargu-skill--user-dir) (lambda () nil)))
				(let ((skills (kargu-skill-list)))
				  (should (= (length skills) 1))
				  (should (equal (plist-get (car skills) :name) "deploy"))
				  (should (equal (plist-get (car skills) :description) "Ship it"))
				  (should (string-search "Run the deploy script" (plist-get (car skills) :body))))
				(should (string-search "<name>deploy</name>" (kargu-skill-format-catalog)))))))

(ert-deftest kargu-skill-load-reports-errors-as-text-test ()
  "A missing name or an unknown skill is an ERROR text that lists what exists."
  (kargu-fs-test--with-tree `(("skills/deploy/SKILL.md" . ,kargu-skill-test--skill))
			    (let ((kargu-permission--override-root root)
				  (kargu-skill--cache nil)
				  (kargu-skill--ttl 0.0))
			      (cl-letf (((symbol-function 'kargu-skill--user-dir) (lambda () nil)))
				(should (string-prefix-p "ERROR: skill name is required" (kargu-skill-load "")))
				(let ((msg (kargu-skill-load "nope")))
				  (should (string-prefix-p "ERROR: skill \"nope\" not found" msg))
				  (should (string-search "deploy" msg)))
				(let ((ok (kargu-skill-load "deploy")))
				  (should (string-search "<skill_content name=\"deploy\">" ok))
				  (should (string-search "Run the deploy script" ok)))))))

(ert-deftest kargu-skill-body-is-capped-test ()
  "A long skill body is cut at `kargu-skill-max-chars'."
  (kargu-fs-test--with-tree `(("skills/long/SKILL.md"
                               . ,(concat "---\nname: long\n---\n" (make-string 500 ?x))))
			    (let ((kargu-permission--override-root root)
				  (kargu-skill--cache nil)
				  (kargu-skill--ttl 0.0)
				  (kargu-skill-max-chars 50))
			      (cl-letf (((symbol-function 'kargu-skill--user-dir) (lambda () nil)))
				(let ((out (kargu-skill-load "long")))
				  (should (< (length out) 300))
				  (should (string-search "truncated" out)))))))

(ert-deftest kargu-search-elisp-globs-match-zero-or-more-directories-test ()
  "A recursive glob includes root files and every nested directory depth."
  (dolist (pattern '("*.el" "**/*.el"))
    (let ((regexp (kargu-search--glob-to-regexp pattern)))
      (dolist (path '("main.el" "src/main.el" "src/deep/main.el"))
        (should (string-match-p regexp path)))
      (should-not (string-match-p regexp "main.elc"))))
  (let ((regexp (kargu-search--glob-to-regexp "src/**/test?.el")))
    (dolist (path '("src/test1.el" "src/a/test2.el" "src/a/b/test3.el"))
      (should (string-match-p regexp path)))
    (dolist (path '("test1.el" "src/test12.el" "src/a/test.elc"))
      (should-not (string-match-p regexp path))))
  (should (string-match-p (kargu-search--glob-to-regexp "main+.el") "main+.el"))
  (should-not (string-match-p (kargu-search--glob-to-regexp "main+.el") "main.el")))

(ert-deftest kargu-search-find-files-fallback-includes-project-root-test ()
  "The public find-files path works without fd or rg, including file targets."
  (kargu-fs-test--with-tree
   '(("main.el" . "x") ("src/child.el" . "x") ("src/deep/grandchild.el" . "x")
     ("Makefile" . "x") ("src/Makefile" . "x"))
   (let ((kargu-permission--override-root root))
     (cl-letf (((symbol-function 'kargu-search-fd-executable) (lambda () nil))
               ((symbol-function 'kargu-search-rg-executable) (lambda () nil)))
       (dolist (pattern '("*.el" "**/*.el"))
         (let ((result (kargu-test-await
                        (lambda (done) (kargu-search-glob done pattern)))))
           (should (equal (sort (split-string result "\n" t) #'string<)
                          '("main.el" "src/child.el" "src/deep/grandchild.el")))))
       (let ((result (kargu-test-await
                      (lambda (done) (kargu-search-glob done "Makefile")))))
         (should (equal (sort (split-string result "\n" t) #'string<)
                        '("Makefile" "src/Makefile"))))
       (should (equal (kargu-test-await
                       (lambda (done) (kargu-search-glob done "*.el" "main.el")))
                      "main.el\n"))))))

(provide 'tests/test-fs)
;;; test-fs.el ends here
