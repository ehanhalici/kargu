;;; tests/test-fs.el --- Tests for the bounded file walk and skill discovery -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'ert)
(require 'cl-lib)
(require 'tests/test-helpers)
(require 'kargu/core)
(require 'kargu/fs)
(require 'kargu/tools/skill)
(require 'kargu/permission/guards)

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

(ert-deftest kargu-fs-walk-cap-counts-visited-files-test ()
  "The cap bounds visited files, whether or not the filter keeps them."
  (kargu-fs-test--with-tree (mapcar (lambda (i) (cons (format "f%d.txt" i) "x")) (number-sequence 1 10))
    (let ((seen 0))
      (kargu-fs-walk root 3 (lambda (_f) (setq seen (1+ seen)) nil))
      (should (= seen 3)))
    (should (= (length (kargu-fs-walk root 4)) 4))))

(ert-deftest kargu-fs-skipped-path-and-relative-path-test ()
  "Skipped components are detected; paths inside the root turn relative."
  (should (kargu-fs-skipped-path-p "/p/node_modules/x.js"))
  (should-not (kargu-fs-skipped-path-p "/p/src/x.js"))
  (should (equal (kargu-rel-path "/p/src/x.js" "/p/") "src/x.js"))
  (should (equal (kargu-rel-path "/elsewhere/x.js" "/p/") "/elsewhere/x.js")))

(ert-deftest kargu-fs-has-file-p-test ()
  "Existence is checked under the given root only."
  (kargu-fs-test--with-tree '(("Cargo.toml" . ""))
    (should (kargu-fs-has-file-p root "Cargo.toml"))
    (should-not (kargu-fs-has-file-p root "go.mod"))
    (should-not (kargu-fs-has-file-p nil "Cargo.toml"))))

(defconst kargu-skill-test--skill
  "---\nname: deploy\ndescription: Ship it\n---\nRun the deploy script.\n")

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

(provide 'tests/test-fs)
;;; test-fs.el ends here
