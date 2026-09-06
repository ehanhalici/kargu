;;; kargu/tools/skill.el --- SKILL.md discovery and load -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Discover SKILL.md files and expose a `skill' tool that loads one
;; by name.  Catalog text is injected into the system prompt.
;; Requires: `kargu/core', `kargu/api', `kargu/fs'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
;; Ensure the package root is on `load-path' during byte/native
;; compilation from a subdirectory (Magit-style kargu/core features).
(eval-and-compile
  (let ((root (locate-dominating-file
               (or (bound-and-true-p byte-compile-current-file)
                   load-file-name
                   buffer-file-name
                   default-directory)
               "kargu.el")))
    (when root
      (add-to-list 'load-path (file-name-as-directory
                               (expand-file-name root))))))

(require 'kargu/core)
(require 'kargu/api)
(require 'kargu/fs)

(defcustom kargu-skill-max-chars 12000
  "Character cap for a loaded skill body."
  :type 'natnum
  :group 'kargu)

(defvar kargu-skill--cache nil
  "Plist :time :root :skills (list of plists).")

(defconst kargu-skill--ttl 8.0
  "Seconds to reuse `kargu-skill--cache'.")

(defun kargu-skill--root ()
  "Project root used for skill discovery."
  (file-name-as-directory
   (expand-file-name
    (or (and (fboundp 'kargu--project-root)
             (ignore-errors (kargu--project-root)))
        default-directory))))

(defun kargu-skill--user-dir ()
  "User-level skills directory, or nil."
  (let ((dir (expand-file-name "kargu/skills"
                               (or (getenv "XDG_CONFIG_HOME")
                                   (expand-file-name ".config" (getenv "HOME"))))))
    (and (file-directory-p dir) dir)))

(defun kargu-skill--relevant-p (path root)
  "Non-nil when PATH looks like a skill file under ROOT or a skills dir."
  (let ((rel (file-relative-name path root)))
    (or (string-match-p "\\`\\(\\.opencode/\\)?skills?/" rel)
        (string-match-p "/skills?/" path)
        (string-match-p "/\\.agents/skills/" path)
        (string-match-p "/\\.claude/skills/" path))))

(defun kargu-skill--parse (path)
  "Parse SKILL.md at PATH into a plist :name :description :path :body."
  (let* ((raw (with-temp-buffer
                (insert-file-contents path)
                (buffer-string)))
         (name (file-name-nondirectory
                (directory-file-name (file-name-directory path))))
         (description nil)
         (body raw)
         (end (and (string-prefix-p "---" raw)
                   (string-match "\n---\n" raw 3))))
    (when end
      (let ((fm (substring raw 4 end)))
        (setq body (substring raw (+ end (length "\n---\n"))))
        (when (string-match "^name:[ \t]*\\(.*\\)$" fm)
          (setq name (string-trim (match-string 1 fm))))
        (when (string-match "^description:[ \t]*\\(.*\\)$" fm)
          (setq description (string-trim (match-string 1 fm))))))
    (list :name name
          :description description
          :path path
          :body body)))

(defun kargu-skill--collect ()
  "Return the list of skill plists for the current workspace."
  (let* ((root (kargu-skill--root))
         (acc nil)
         (visit (lambda (path)
                  (when (and (string-equal (file-name-nondirectory path) "SKILL.md")
                             (or (kargu-skill--relevant-p path root)
                                 (string-prefix-p (or (kargu-skill--user-dir) "\0") path)))
                    (condition-case-unless-debug err
                        (push (kargu-skill--parse path) acc)
                      (error
                       (kargu-log 'warn "skill parse failed %s: %s"
                                        path (error-message-string err))))))))
    (kargu-fs-walk root 400 (lambda (f)
                              (when (string-equal (file-name-nondirectory f) "SKILL.md")
                                (funcall visit f))
                              nil))
    (when-let* ((user (kargu-skill--user-dir)))
      (kargu-fs-walk user 100 (lambda (f)
                                (when (string-equal (file-name-nondirectory f) "SKILL.md")
                                  (funcall visit f))
                                nil)))
    (nreverse acc)))

(defun kargu-skill-list ()
  "Cached list of skill plists."
  (let ((root (kargu-skill--root)))
    (if (and kargu-skill--cache
             (equal (plist-get kargu-skill--cache :root) root)
             (< (- (float-time) (or (plist-get kargu-skill--cache :time) 0))
                kargu-skill--ttl))
        (plist-get kargu-skill--cache :skills)
      (let ((skills (kargu-skill--collect)))
        (setq kargu-skill--cache (list :time (float-time) :root root :skills skills))
        skills))))

(defun kargu-skill-format-catalog ()
  "System-prompt block listing available skills, or nil."
  (let ((skills (kargu-skill-list)))
    (when skills
      (concat
       "Skills provide specialized instructions for specific tasks.\n"
       "Use the skill tool with the skill name when a task matches.\n"
       "<available_skills>\n"
       (mapconcat
        (lambda (s)
          (format "  <skill>\n    <name>%s</name>\n    <description>%s</description>\n  </skill>"
                  (plist-get s :name)
                  (or (plist-get s :description) "")))
        skills
        "\n")
       "\n</available_skills>\n"))))

(defun kargu-skill-load (name)
  "Return the body of skill NAME, or an error string."
  (let* ((want (and (stringp name) (string-trim name)))
         (skills (kargu-skill-list))
         (hit (cl-find want skills :key (lambda (s) (plist-get s :name))
                       :test #'string-equal)))
    (cond
     ((not (kargu--nonempty want))
      "ERROR: skill name is required")
     ((null hit)
      (format "ERROR: skill %S not found. Available: %s"
              want
              (or (mapconcat (lambda (s) (plist-get s :name)) skills ", ")
                  "none")))
     (t
      (let* ((body (or (plist-get hit :body) ""))
             (limit kargu-skill-max-chars)
             (capped (if (> (length body) limit)
                         (concat (substring body 0 limit) "\n... [truncated]\n")
                       body)))
        (format "<skill_content name=\"%s\">\n# Skill: %s\n\n%s\nBase directory: %s\n</skill_content>"
                (plist-get hit :name)
                (plist-get hit :name)
                (string-trim capped)
                (file-name-directory (plist-get hit :path))))))))

(defun kargu-skill-register-tools ()
  "Register the skill tool."
  (kargu-register-tool
   "skill"
   "Load a named skill's instructions. Use when the task matches an available_skills entry."
   '(("type" . "object")
     ("properties" . (("name" . (("type" . "string")
                                 ("description" . "Skill name from available_skills.")))))
     ("required" . ["name"]))
   (lambda (args)
     (kargu-skill-load (kargu--tool-arg args "name")))))

(kargu-skill-register-tools)

(provide 'kargu/tools/skill)

;;; kargu/tools/skill.el ends here
