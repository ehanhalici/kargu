;;; skill.el --- SKILL.md discovery and load -*- lexical-binding: t; -*-

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
(require 'xml)
(require 'rx)
(require 'kargu/core)
(require 'kargu/api)
(require 'kargu/fs)

(defcustom kargu-skill-max-chars 12000
  "Character cap for a loaded skill body."
  :type 'natnum
  :group 'kargu)

(defcustom kargu-skill-max-file-bytes 262144
  "Maximum skill file size read during discovery, in bytes."
  :type 'natnum
  :group 'kargu)

(defvar kargu-skill--cache nil
  "Plist :time :root :skills (list of plists).")

(defconst kargu-skill--ttl 8.0
  "Seconds to reuse `kargu-skill--cache'.")

(defconst kargu-skill--project-directories
  '("skills" "skill" ".agents/skills" ".claude/skills" ".codex/skills")
  "Standard project directories inspected before the general file walk.")
(defconst kargu-skill--project-scan-limit 400
  "Maximum ordinary files visited per project skill fallback scan.")
(defconst kargu-skill--user-scan-limit 100
  "Maximum ordinary files visited by the user skill fallback scan.")

(declare-function kargu-permission-project-root "kargu/permission/guards" (&optional buffer))

(defun kargu-skill--root ()
  "Project root used for skill discovery."
  (kargu-permission-project-root))

(defun kargu-skill--user-dir ()
  "User-level skills directory, or nil."
  (let ((dir (expand-file-name "kargu/skills"
                               (or (getenv "XDG_CONFIG_HOME")
                                   (expand-file-name ".config" (getenv "HOME"))))))
    (and (file-directory-p dir) dir)))

(defun kargu-skill--relevant-p (path root)
  "Check whether PATH names a skill below ROOT or a skills directory."
  (save-match-data
    (string-match-p (rx (or bos "/") "skill" (? "s") "/")
                    (file-relative-name path root))))

(defun kargu-skill--read (path)
  "Read bounded UTF-8 skill text at PATH, rejecting oversized files."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally path nil 0 (1+ kargu-skill-max-file-bytes))
    (when (> (buffer-size) kargu-skill-max-file-bytes)
      (error "Skill file exceeds %d bytes: %s" kargu-skill-max-file-bytes path))
    (replace-regexp-in-string "\r\n" "\n"
                              (decode-coding-string (buffer-string) 'utf-8) t t)))

(defun kargu-skill--scalar (value)
  "Read a plain or quoted YAML string VALUE without evaluating it."
  (setq value (string-trim value))
  (cond
   ((and (string-prefix-p "\"" value) (string-suffix-p "\"" value))
    (json-parse-string value))
   ((and (string-prefix-p "'" value) (string-suffix-p "'" value))
    (replace-regexp-in-string "''" "'" (substring value 1 -1) t t))
   (t (string-trim (car (split-string value (rx (+ blank) "#")))))))

(defun kargu-skill--fold-lines (lines)
  "Fold ordinary LINES while preserving paragraphs and extra indentation."
  (let (previous parts)
    (dolist (line lines)
      (when previous
        (push (cond
               ((string-empty-p line) "\n")
               ((string-empty-p previous) "")
               ((or (string-prefix-p " " previous) (string-prefix-p " " line)) "\n")
               (t " ")) parts))
      (push line parts)
      (setq previous line))
    (string-join (nreverse parts) "")))

(defun kargu-skill--block-value (text folded)
  "Read an indented scalar from TEXT, optionally applying FOLDED style.
Normalize surrounding metadata whitespace; preserve literal internal lines."
  (let (lines)
    (catch 'kargu-skill-block-end
      (dolist (line (split-string text "\n"))
        (unless (or (string-empty-p line) (string-match-p (rx bos blank) line))
          (throw 'kargu-skill-block-end nil))
        (push line lines)))
    (setq lines (nreverse lines))
    (let* ((indents (delq nil (mapcar
                              (lambda (line)
                                (when (and (not (string-empty-p (string-trim line)))
                                           (string-match (rx bos (+ blank)) line))
                                  (length (match-string 0 line)))) lines)))
           (indent (if indents (apply #'min indents) 0)))
      (setq lines (mapcar (lambda (line) (substring line (min indent (length line)))) lines))
      (string-trim (if folded (kargu-skill--fold-lines lines)
                     (string-join lines "\n"))))))

(defun kargu-skill--field (frontmatter key)
  "Read string KEY from FRONTMATTER, including folded and literal scalars."
  (save-match-data
    (when (string-match (concat "^" (regexp-quote key) (rx ":" (* blank) (group (* nonl)) eol))
                        frontmatter)
      (let ((value (string-trim (match-string 1 frontmatter)))
            (rest (substring frontmatter (min (length frontmatter) (1+ (match-end 0))))))
        (if (string-match-p (rx bos (any "|>") (? (any "+-")) (* blank) (? "#" (* nonl)) eos) value)
            (kargu-skill--block-value rest (string-prefix-p ">" value))
          (kargu-skill--scalar value))))))

(defun kargu-skill--parse (path)
  "Parse SKILL.md at PATH into a plist :name :description :path :body."
  (save-match-data
    (let* ((raw (kargu-skill--read path))
           (name (file-name-nondirectory
                  (directory-file-name (file-name-directory path))))
           description (body raw))
      (when (string-match (rx bos "---" "\n") raw)
        (let ((start (match-end 0)))
          (when (string-match (rx bol "---" (or "\n" eos)) raw start)
            (let ((frontmatter (substring raw start (match-beginning 0))))
              (setq body (substring raw (match-end 0))
                    name (or (kargu-nonempty (kargu-skill--field frontmatter "name")) name)
                    description (kargu-skill--field frontmatter "description"))))))
      (list :name name :description description :path path :body body))))

(defun kargu-skill--metadata-files (directory)
  "Inspect DIRECTORY and immediate skill folders before traversing their assets."
  (let ((children (condition-case nil
                      (seq-filter #'file-directory-p
                                  (directory-files directory t directory-files-no-dot-files-regexp))
                    (file-error nil))) paths)
    (dolist (dir (cons directory (seq-take children kargu-fs-max-visited-directories)))
      (let ((path (expand-file-name "SKILL.md" dir)))
        (when (and (file-regular-p path)
                   (file-in-directory-p path directory)
                   (or (equal dir directory)
                       (not (member (file-name-nondirectory dir) kargu-fs-skip-dirs))))
          (push path paths))))
    (nreverse paths)))

(defun kargu-skill--paths-under (directory limit)
  "Find metadata in DIRECTORY first, then walk at most LIMIT ordinary files."
  (when (file-directory-p directory)
    (append (kargu-skill--metadata-files directory)
            (kargu-fs-walk directory limit
                           (lambda (path)
                             (equal (file-name-nondirectory path) "SKILL.md"))))))

(defun kargu-skill--collect-paths (root)
  "Find skill metadata in ROOT and user directories without scanning assets first."
  (let (paths)
    (dolist (relative kargu-skill--project-directories)
      (let ((directory (expand-file-name relative root)))
        (when (and (file-directory-p directory) (file-in-directory-p directory root))
          (dolist (path (kargu-skill--paths-under directory kargu-skill--project-scan-limit))
            (push path paths)))))
    (dolist (path (kargu-fs-walk
                  root kargu-skill--project-scan-limit
                  (lambda (file) (and (equal (file-name-nondirectory file) "SKILL.md")
                                     (kargu-skill--relevant-p file root)))))
      (push path paths))
    (when-let* ((user (kargu-skill--user-dir)))
      (dolist (path (kargu-skill--paths-under user kargu-skill--user-scan-limit))
        (push path paths)))
    (delete-dups (nreverse paths))))

(defun kargu-skill--collect ()
  "Return parsed skills for the current workspace, skipping invalid metadata."
  (let (skills)
    (dolist (path (kargu-skill--collect-paths (kargu-skill--root)))
      (condition-case err
          (push (kargu-skill--parse path) skills)
        (error (kargu-log 'warn "Skill parse failed %s: %s"
                           path (error-message-string err)))))
    (nreverse skills)))

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
                  (xml-escape-string (plist-get s :name))
                  (xml-escape-string (or (plist-get s :description) ""))))
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
     ((not (kargu-nonempty want))
      "ERROR: skill name is required")
     ((null hit)
      (format "ERROR: skill %S not found. Available: %s"
              want
              (or (mapconcat (lambda (s) (plist-get s :name)) skills ", ")
                  "none")))
     (t
      (let* ((body (or (plist-get hit :body) ""))
             (limit kargu-skill-max-chars)
             (capped (kargu-cap-text body limit "skill")))
        (format "<skill_content name=\"%s\">\n# Skill: %s\n\n%s\nBase directory: %s\n</skill_content>"
                (xml-escape-string (plist-get hit :name))
                (xml-escape-string (plist-get hit :name))
                (string-trim capped)
                (xml-escape-string (file-name-directory (plist-get hit :path)))))))))

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

(provide 'kargu/tools/skill)

;;; skill.el ends here
