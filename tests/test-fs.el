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
(require 'tests/test-bridge)

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
  (kargu-bridge-test--with-core
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
        (should-not (string-search ".git/secret" output)))))))

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

(ert-deftest kargu-search-grep-does-not-follow-external-links-test ()
  "Native search cannot follow recursive symlinks outside the project.
The forced GNU fallback is also exercised in Rust's real-pipe matrix."
  (kargu-bridge-test--with-core
  (kargu-fs-test--with-tree '(("inside.txt" . "needle inside\n"))
			    (let ((outside (make-temp-file "kargu-grep-external-" t))
                                  (kargu-permission--override-root root))
			      (unwind-protect
				  (progn
				    (write-region "needle outside-secret\n" nil (expand-file-name "secret.txt" outside) nil 'silent)
				    (make-symbolic-link outside (expand-file-name "external" root))
				    (let ((result (kargu-test-await
						   (lambda (done) (kargu-search-grep done "needle" nil nil 20)))))
				      (should (string-search "inside" result))
				      (should-not (string-search "outside-secret" result))))
				(delete-directory outside t))))))

(ert-deftest kargu-search-grep-native-global-budget-test ()
  "Public native search uses one global cap and never the Elisp process runner.
Both engines' raw lookahead/cleanup and argv policy live in Rust tests."
  (kargu-bridge-test--with-core
  (kargu-fs-test--with-tree
      (cl-loop for index below 20
               collect (cons (format "%02d.txt" index) "needle\n"))
    (let ((kargu-permission--override-root root))
      (cl-letf (((symbol-function 'kargu-process-run)
                 (lambda (&rest _) (ert-fail "Legacy search executed"))))
        (let ((out (kargu-test-await
                    (lambda (done) (kargu-search-grep done "needle" nil nil 3)))))
          (should (= (length (split-string out "\n" t)) 4))
          (should (string-search "additional hits omitted" out))
          (should-not (string-prefix-p "ERROR:" out))))))))

(ert-deftest kargu-search-grep-exact-budget-has-no-omission-test ()
  "An exact number of hits is not reported as truncated."
  (kargu-bridge-test--with-core
  (kargu-fs-test--with-tree '(("a.txt" . "needle\nneedle\nneedle\n"))
    (let ((kargu-permission--override-root root))
      (let ((out (kargu-test-await
                  (lambda (callback) (kargu-search-grep callback "needle" nil nil 3)))))
        (should (= (length (split-string out "\n" t)) 3))
        (should-not (string-search "omitted" out)))))))

(ert-deftest kargu-search-grep-budget-preserves-empty-and-invalid-test ()
  "No matches and invalid patterns retain their distinct outcomes."
  (kargu-bridge-test--with-core
  (kargu-fs-test--with-tree '(("a.txt" . "needle\n"))
    (let ((kargu-permission--override-root root))
        (dolist (pattern '("absent" "["))
          (let ((out (kargu-test-await
                      (lambda (callback)
                        (kargu-search-grep callback pattern nil nil 3)))))
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

(ert-deftest kargu-search-native-port-captures-shared-directory-policy-test ()
  "The native port captures configuration and never starts an Elisp search."
  (let ((connection (kargu-bridge--connection-create :state 'ready)) seen result)
    (cl-letf (((symbol-function 'kargu-bridge-ensure)
               (lambda (callback) (funcall callback connection nil) #'ignore))
              ((symbol-function 'kargu-bridge-find-files)
               (lambda (_connection arguments callback &rest _options)
                 (setq seen arguments)
                 (funcall callback (kargu-bridge--object "text" "visible.el\n") nil)
                 nil))
              ((symbol-function 'kargu-process-run) (lambda (&rest _) (ert-fail "Legacy search executed"))))
      (kargu-search-glob (lambda (text) (setq result text)) "*.el")
      (should (equal (gethash "skip_directories" seen) (vconcat kargu-fs-skip-dirs)))
      (should (equal (gethash "pattern" seen) "*.el"))
      (should (= (gethash "max_files" seen) kargu-fs-max-listed-files))
      (should (= (gethash "max_directories" seen) kargu-fs-max-visited-directories))
      (should (equal result "visible.el\n")))))

(ert-deftest kargu-search-native-parent-cancel-revokes-rpc-and-suppresses-late-result-test ()
  "Stop revokes only the captured request and cannot publish a late result."
  (let* ((kargu--loop-run nil) (kargu-execution--current nil)
         (kargu-async--current-task nil)
         (parent (kargu-async-start #'ignore :owner nil :parent nil))
         (connection (kargu-bridge--connection-create :state 'ready))
         reply cancelled delivered child)
    (unwind-protect
        (cl-letf (((symbol-function 'kargu-bridge-ensure)
                   (lambda (callback) (funcall callback connection nil) #'ignore))
                  ((symbol-function 'kargu-bridge-find-files)
                   (lambda (_connection _arguments callback &rest _options)
                     (setq reply callback) "owned-rpc"))
                  ((symbol-function 'kargu-bridge-cancel)
                   (lambda (conn id) (push (cons conn id) cancelled))))
          (let ((kargu-async--current-task parent))
            (setq child (kargu-search-glob (lambda (text) (setq delivered text)) "*.el")))
          (kargu-async-cancel parent)
          (should (eq (kargu-async-task-state child) :cancelled))
          (should (equal cancelled (list (cons connection "owned-rpc"))))
          (funcall reply (kargu-bridge--object "text" "late.el\n") nil)
          (should-not delivered)
          (should-not (kargu-async-task-children parent)))
      (kargu-async-cancel parent))))

(ert-deftest kargu-search-native-unavailable-is-an-explicit-error-without-fallback-test ()
  "A missing binary reports failure once rather than re-entering legacy code."
  (let ((count 0) result)
    (cl-letf (((symbol-function 'kargu-bridge-ensure)
               (lambda (callback)
                 (funcall callback nil (kargu-bridge--fault "startup_failed")) #'ignore))
              ((symbol-function 'kargu-process-run) (lambda (&rest _) (ert-fail "Legacy search executed"))))
      (kargu-search-glob (lambda (text) (cl-incf count) (setq result text)) "*.el")
      (should (= count 1))
      (should (string-prefix-p "ERROR: Rust core unavailable" result)))))

(ert-deftest kargu-search-native-canonical-and-alias-tools-use-existing-gate-test ()
  "Actual registered tools reach Rust through the existing read-only gate."
  (kargu-bridge-test--with-core
    (kargu-fs-test--with-tree '(("src/main.el" . "fixture") ("node_modules/hidden.el" . "fixture"))
      (let ((kargu--tool-registry (kargu-tool-registry-create))
            (kargu-permission--override-root root) (kargu--loop-run nil))
        (kargu-search-register-tools)
        (dolist (mode '(ask plan debug agent))
          (let ((context (kargu-tool-execution-context-create
                          :root root :mode mode
                          :policy-revision (kargu-tool-registry-revision kargu--tool-registry))))
            (dolist (name '("find_files" "find_files_by_glob" "find" "fd" "glob"))
              (should (equal (kargu-test-await
                              (lambda (done)
                                (kargu-tool-gate-execute
                                 kargu--tool-registry context name '(("pattern" . "*.el")) :callback done)))
                             "src/main.el\n")))))
        (should (= 0 (kargu-tool-execution-active-task-count kargu--tool-registry "find_files")))
        (should (= 0 (hash-table-count (kargu-bridge-connection-pending conn))))))))

(ert-deftest kargu-search-listing-without-callback-is-explicitly-nonblocking-test ()
  "The old synchronous signature never starts an implicit wait or scanner."
  (cl-letf (((symbol-function 'kargu-bridge-ensure) (lambda (&rest _) (ert-fail "Unexpected startup"))))
    (should (string-prefix-p "ERROR: directory listing runs asynchronously" (kargu-search-list-files)))))

(ert-deftest kargu-search-listing-parent-cancel-revokes-rpc-and-ignores-late-result-test ()
  "A cancelled native listing cannot deliver stale output or kill a sibling."
  (let* ((kargu--loop-run nil) (kargu-execution--current nil) (kargu-async--current-task nil)
         (parent (kargu-async-start #'ignore :owner nil :parent nil))
         (connection (kargu-bridge--connection-create :state 'ready)) reply cancelled delivered child)
    (unwind-protect
        (cl-letf (((symbol-function 'kargu-bridge-ensure)
                   (lambda (callback) (funcall callback connection nil) #'ignore))
                  ((symbol-function 'kargu-bridge-list-files)
                   (lambda (_connection _arguments callback &rest _options) (setq reply callback) "list-rpc"))
                  ((symbol-function 'kargu-bridge-cancel)
                   (lambda (conn id) (push (cons conn id) cancelled))))
          (let ((kargu-async--current-task parent))
            (setq child (kargu-search-list-files nil (lambda (text) (setq delivered text)))))
          (kargu-async-cancel parent)
          (should (eq (kargu-async-task-state child) :cancelled))
          (should (equal cancelled (list (cons connection "list-rpc"))))
          (funcall reply (kargu-bridge--object "text" "late") nil)
          (should-not delivered))
      (kargu-async-cancel parent))))

(ert-deftest kargu-search-listing-captures-policy-and-does-not-rescan-in-elisp-test ()
  "Root, target and exclusions are captured without an Elisp directory scan."
  (let ((connection (kargu-bridge--connection-create :state 'ready))
        seen result)
    (cl-letf (((symbol-function 'kargu-bridge-ensure)
               (lambda (callback) (funcall callback connection nil) #'ignore))
              ((symbol-function 'kargu-bridge-list-files)
               (lambda (_conn arguments callback &rest _options)
                 (setq seen arguments)
                 (funcall callback (kargu-bridge--object "text" "native-listing") nil) nil))
              ((symbol-function 'directory-files) (lambda (&rest _) (ert-fail "Elisp directory scan executed"))))
      (kargu-search-list-files nil (lambda (text) (setq result text)))
      (should-not (gethash "max_entries" seen))
      (should (equal (gethash "skip_directories" seen) (vconcat kargu-fs-skip-dirs)))
      (should (stringp (gethash "root" seen)))
      (should (stringp (gethash "path" seen)))
      (should (equal result "native-listing")))))

(ert-deftest kargu-search-listing-native-errors-and-invalid-results-finish-once-test ()
  "Malformed output and native failure remain explicit terminal errors."
  (let ((connection (kargu-bridge--connection-create :state 'ready)))
    (dolist (failure '(nil native unavailable))
      (let ((count 0) result)
        (cl-letf (((symbol-function 'kargu-bridge-ensure)
                   (lambda (callback)
                     (funcall callback (unless (eq failure 'unavailable) connection)
                              (and (eq failure 'unavailable) (kargu-bridge--fault "unavailable"))) #'ignore))
                  ((symbol-function 'kargu-bridge-list-files)
                   (lambda (_conn _args callback &rest _options)
                     (dotimes (_ 2)
                       (funcall callback (kargu-bridge--object "text" 7)
                                (and (eq failure 'native) (kargu-bridge--fault "io_error")))) nil)))
          (kargu-search-list-files nil (lambda (text) (cl-incf count) (setq result text)))
          (should (= count 1))
          (should (string-prefix-p "ERROR:" result)))))))

(ert-deftest kargu-search-listing-canonical-alias-mode-and-path-equivalence-test ()
  "Real list_files/ls/dir calls keep their schema and read-only mode gate."
  (kargu-bridge-test--with-core
    (kargu-fs-test--with-tree '(("root.el" . "x") ("src/child.el" . "x") ("node_modules/ignored.el" . "x"))
      (let ((kargu--tool-registry (kargu-tool-registry-create))
            (kargu-permission--override-root root) (kargu--loop-run nil))
        (kargu-search-register-tools)
        (dolist (mode '(ask plan debug agent))
          (let ((context (kargu-tool-execution-context-create
                          :root root :mode mode :policy-revision (kargu-tool-registry-revision kargu--tool-registry))))
            (dolist (name '("list_files" "ls" "dir"))
              (let ((text (kargu-test-await
                           (lambda (done) (kargu-tool-gate-execute kargu--tool-registry context name nil :callback done)))))
                (should (string-search "src" text))
                (should (string-search "root.el" text))
                (should-not (string-search "node_modules" text))))))
        (should (string-search "child.el" (kargu-test-await (lambda (done) (kargu-search-list-files "src" done)))))
        (should (string-prefix-p "ERROR:" (kargu-test-await (lambda (done) (kargu-search-list-files "root.el" done)))))
        (should (= 0 (kargu-tool-execution-active-task-count kargu--tool-registry "list_files")))
        (should (= 0 (hash-table-count (kargu-bridge-connection-pending conn))))))))

(ert-deftest kargu-search-listing-empty-symlink-and-custom-exclusion-test ()
  "Real GNU output retains empty directory, symlink and exclusion semantics."
  (kargu-bridge-test--with-core
    (kargu-fs-test--with-tree '(("src/a.el" . "x") ("src/b.el" . "x"))
      (let ((kargu-permission--override-root root))
        (make-directory (expand-file-name "empty" root))
        (make-symbolic-link "missing-target" (expand-file-name "broken" root))
        (should (equal (kargu-test-await (lambda (done) (kargu-search-list-files "empty" done))) "total 0\n"))
        (should (string-search "broken -> missing-target" (kargu-test-await (lambda (done) (kargu-search-list-files nil done)))))
        (let ((kargu-fs-skip-dirs '("src" "broken")))
          (let ((text (kargu-test-await (lambda (done) (kargu-search-list-files nil done)))))
            (should (string-search "empty" text))
            (should-not (string-search "broken" text))
            (should-not (string-search "src" text))))))))

(defconst kargu-skill-test--skill
  "---\nname: deploy\ndescription: Ship it\n---\nRun the deploy script.\n")

(defun kargu-skill-test--refresh ()
  "Await a real catalog refresh, raising failures in tests only."
  (let ((result (kargu-test-await #'kargu-skill-refresh)))
    (should (kargu-ok-p result))
    (kargu-result-value result)))

(defun kargu-skill-test--load (name)
  "Await the real native load of NAME in tests only."
  (kargu-test-await (lambda (done) (kargu-skill-load name done))))

(defmacro kargu-skill-test--with-tree (files &rest body)
  "Run BODY with FILES in a real native temporary skill workspace."
  (declare (indent 1))
  `(kargu-bridge-test--with-core
    (kargu-fs-test--with-tree ,files
      (let ((kargu-permission--override-root root)
            (kargu-skill--cache nil) (kargu-skill--intent nil))
        (cl-letf (((symbol-function 'kargu-skill-refresh) kargu-test-real-skill-refresh))
          ,@body)))))

(ert-deftest kargu-skill-metadata-is-escaped-and-file-reads-are-bounded-test ()
  "Real Rust metadata cannot close catalog tags; oversized files are skipped."
  (kargu-skill-test--with-tree
      '(("skills/example/SKILL.md" . "---\nname: <name&>\ndescription: </description><injected/>\n---\nbody")
        ("skills/huge/SKILL.md" . "oversized"))
    (let ((catalog (kargu-skill-test--refresh)))
      (should (string-search "&lt;name&amp;&gt;" catalog))
      (should (string-search "&lt;/description&gt;&lt;injected/&gt;" catalog))
      (should-not (string-search "<injected/>" catalog)))
    (should (string-search "name=\"&lt;name&amp;&gt;\"" (kargu-skill-test--load "<name&>")))
    (let ((kargu-skill-max-file-bytes 4))
      (should (string-search "unreadable_or_invalid=2" (kargu-skill-test--refresh)))
      (should-not (kargu-skill-list)))))

(ert-deftest kargu-skill-frontmatter-handles-crlf-eof-and-block-scalars-test ()
  "Native string metadata supports CRLF, EOF delimiters, quoting and blocks."
  (dolist (case '(("---\r\nname: 'quoted name'\r\ndescription: \"line\\nvalue\"\r\n---" "quoted name" "line\nvalue")
                  ("---\nname: folded\ndescription: >-\n  first line\n  second line\n\n  paragraph two\n---\nbody" "folded" "first line second line\nparagraph two")
                  ("---\nname: literal\ndescription: |\n  first\n  second\n---\nbody" "literal" "first\nsecond")))
    (kargu-skill-test--with-tree `(("skills/sample/SKILL.md" . ,(car case)))
      (kargu-skill-test--refresh)
      (let ((skill (car (kargu-skill-list))))
        (should (equal (plist-get skill :name) (nth 1 case)))
        (should (equal (plist-get skill :description) (nth 2 case)))))))

(ert-deftest kargu-skill-discovery-prioritizes-metadata-over-project-assets-test ()
  "Root files and a skill's examples cannot hide sibling skill metadata."
  (kargu-skill-test--with-tree
      (append (cl-loop for index below 450 collect
                       (cons (format "asset-%04d.txt" index) "x"))
              (cl-loop for index below 450 collect
                       (cons (format "skills/first/examples/asset-%04d.txt" index) "x"))
              '(("skills/first/SKILL.md" . "---\nname: first\n---\nfirst body")
                ("skills/second/SKILL.md" . "---\nname: second\n---\nsecond body")
                (".agents/skills/third/SKILL.md" . "---\nname: third\n---\nthird body")))
    (should (string-search "Skill discovery incomplete" (kargu-skill-test--refresh)))
    (should (equal (sort (mapcar (lambda (s) (plist-get s :name)) (kargu-skill-list)) #'string<)
                   '("first" "second" "third")))))

(ert-deftest kargu-skill-prioritized-discovery-still-confines-symlinks-test ()
  "Direct metadata discovery never follows project links outside the root."
  (kargu-skill-test--with-tree '(("skills/local/SKILL.md" . "local body"))
    (let ((outside (make-temp-file "kargu-foreign-skills-" t)))
      (unwind-protect
          (progn
            (with-temp-file (expand-file-name "SKILL.md" outside) (insert "foreign body"))
            (make-directory (expand-file-name ".agents" root))
            (make-symbolic-link outside (expand-file-name ".agents/skills" root))
            (make-symbolic-link outside (expand-file-name "skills/escape" root))
            (kargu-skill-test--refresh)
            (should (equal (mapcar (lambda (s) (plist-get s :name)) (kargu-skill-list)) '("local"))))
        (delete-directory outside t)))))

(ert-deftest kargu-skill-discovery-parses-front-matter-test ()
  "Native catalog retains name, description and path; named load supplies body."
  (kargu-skill-test--with-tree `(("skills/deploy/SKILL.md" . ,kargu-skill-test--skill)
                               ("src/SKILL.md" . "not a skill dir"))
    (kargu-skill-test--refresh)
    (let ((skills (kargu-skill-list)))
      (should (= (length skills) 1))
      (should (equal (plist-get (car skills) :name) "deploy"))
      (should (equal (plist-get (car skills) :description) "Ship it"))
      (should (equal (plist-get (car skills) :path) (expand-file-name "skills/deploy/SKILL.md" root))))
    (should (string-search "Run the deploy script" (kargu-skill-test--load "deploy")))
    (should (string-search "<name>deploy</name>" (kargu-skill-format-catalog)))))

(ert-deftest kargu-skill-load-reports-errors-as-text-test ()
  "Missing/unknown names and synchronous calls fail explicitly."
  (kargu-skill-test--with-tree `(("skills/deploy/SKILL.md" . ,kargu-skill-test--skill))
    (should (string-prefix-p "ERROR:" (kargu-skill-test--load "")))
    (should (string-search "asynchronously" (kargu-skill-load "deploy")))
    (let ((text (kargu-skill-test--load "nope")))
      (should (string-prefix-p "ERROR: skill \"nope\" not found" text))
      (should (string-search "deploy" text)))
    (should (string-search "<skill_content name=\"deploy\">" (kargu-skill-test--load "deploy")))))

(ert-deftest kargu-skill-body-is-capped-test ()
  "A Unicode body is capped by native characters and reread on every load."
  (kargu-skill-test--with-tree `(("skills/long/SKILL.md" . ,(concat "---\nname: long\n---\n" (make-string 500 ?😀))))
    (let ((kargu-skill-max-chars 50))
      (let ((out (kargu-skill-test--load "long")))
        (should (< (length out) 350))
        (should (string-search "truncated" out))))
    (with-temp-file (expand-file-name "skills/long/SKILL.md" root) (insert "fresh instructions"))
    (should (string-search "fresh instructions" (kargu-skill-test--load "long")))))

(ert-deftest kargu-search-legacy-glob-implementation-is-removed-test ()
  "Matching fixtures now live in Rust; no second implementation may execute."
  (dolist (function '(kargu-search--glob-to-regexp kargu-search--normalize-glob
                      kargu-search--glob-elisp kargu-search--glob-fd kargu-search--glob-rg
                      kargu-search--glob-fallback kargu-search--format-files))
    (should-not (fboundp function))))

(ert-deftest kargu-search-native-find-files-includes-project-root-test ()
  "Public discovery uses the real Rust binary, including file targets."
  (kargu-bridge-test--with-core
  (kargu-fs-test--with-tree
   '(("main.el" . "x") ("src/child.el" . "x") ("src/deep/grandchild.el" . "x")
     ("Makefile" . "x") ("src/Makefile" . "x"))
   (let ((kargu-permission--override-root root))
     (cl-letf (((symbol-function 'kargu-process-run) (lambda (&rest _) (ert-fail "Legacy search executed"))))
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
                      "main.el\n")))))))

(ert-deftest kargu-search-native-grep-captures-policy-without-legacy-engine-test ()
  "Native grep captures output/timeout settings and cannot execute the old engine."
  (let ((connection (kargu-bridge--connection-create :state 'ready)) seen result
        (kargu-process-timeout nil) (kargu-process-max-bytes 1234)
        (kargu-fs-skip-dirs '(".git" "literal*")))
    (cl-letf (((symbol-function 'kargu-bridge-ensure)
               (lambda (callback) (funcall callback connection nil) #'ignore))
              ((symbol-function 'kargu-bridge-grep)
               (lambda (_connection arguments callback &rest _options)
                 (setq seen arguments)
                 (funcall callback (kargu-bridge--object "text" "native hit\n" "outcome" "ok") nil)))
              ((symbol-function 'kargu-process-run)
               (lambda (&rest _) (ert-fail "Legacy search executed"))))
      (kargu-search-grep (lambda (value) (setq result value)) "-needle" nil "**/*.el" 3)
      (should (equal result "native hit\n"))
      (should (eq (gethash "timeout_ms" seen) :json-null))
      (should (= (gethash "output_bytes" seen) 1234))
      (should (= (gethash "max_matches" seen) 3))
      (should (equal (gethash "pattern" seen) "-needle"))
      (should (equal (gethash "glob" seen) "**/*.el"))
      (should (equal (gethash "skip_directories" seen) [".git" "literal*"])))))

(ert-deftest kargu-search-legacy-grep-engine-is-removed-test ()
  "There is no second grep argv, output or process implementation in Elisp."
  (dolist (function '(kargu-search--run kargu-search--rg-exclude-args
                      kargu-search--truncate-lines kargu-search--grep-report
                      kargu-search--grep-rg kargu-search--grep-gnu))
    (should-not (fboundp function))))

(provide 'tests/test-fs)
;;; test-fs.el ends here
