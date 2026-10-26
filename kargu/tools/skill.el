;;; skill.el --- Owned native skill discovery and loading -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Rust owns traversal, regular-file capture, metadata parsing and presentation.
;; Prompt readers observe the last completed buffer/session catalog only.

;;; Code:

(require 'cl-lib)
(require 'kargu/core/group)
(require 'kargu/contract/result)
(require 'kargu/api/tools)
(require 'kargu/bridge/read)
(require 'kargu/json)
(require 'kargu/fs)
(require 'kargu/permission/guards)

(defcustom kargu-skill-max-chars 12000
  "Character cap for a loaded skill body (0..32768)."
  :type 'natnum :group 'kargu)

(defcustom kargu-skill-max-file-bytes 262144
  "Maximum SKILL.md source bytes per file (0..1048576)."
  :type 'natnum :group 'kargu)

(defvar-local kargu-skill--cache nil
  "Completed native catalog with captured inputs and session identity.")
(defvar-local kargu-skill--intent nil
  "Identity of this buffer's most recent admitted catalog refresh.")
(defvar kargu-chat--project-root)
(defvar kargu-context-buffer)

(defun kargu-skill--owner-key ()
  "Return memory-backed context and settings used to qualify an observation."
  (list (copy-sequence default-directory) major-mode
        (and kargu-permission--override-root (copy-sequence kargu-permission--override-root))
        (and (bound-and-true-p kargu-chat--project-root) (copy-sequence kargu-chat--project-root))
        (bound-and-true-p kargu-context-buffer)
        (kargu-skill--user-dir) (vconcat (mapcar #'copy-sequence kargu-fs-skip-dirs))
        kargu-fs-max-visited-directories kargu-skill-max-file-bytes kargu-skill-max-chars))

(defun kargu-skill--same-inputs-p (left right)
  "Compare captured LEFT and fresh RIGHT intents by their closed wire value."
  (and (cl-every (lambda (key) (equal (gethash key left) (gethash key right)))
                 '("root" "user_root" "skip_directories" "max_directories" "max_file_bytes" "body_chars"))
       (let ((lq (gethash "query" left)) (rq (gethash "query" right)))
         (and (equal (gethash "operation" lq) (gethash "operation" rq))
              (equal (gethash "name" lq) (gethash "name" rq))))))

(defun kargu-skill--user-dir ()
  "Return the explicit user skill search grant without probing the filesystem."
  (expand-file-name "kargu/skills"
                    (or (getenv "XDG_CONFIG_HOME") (expand-file-name "~/.config"))))

(defun kargu-skill--inputs (query)
  "Capture bounded editor search settings and the closed native QUERY."
  (kargu-bridge--object
   "root" (kargu-permission-project-root)
   "user_root" (or (kargu-skill--user-dir) :json-null)
   "skip_directories" (vconcat kargu-fs-skip-dirs)
   "max_directories" kargu-fs-max-visited-directories
   "max_file_bytes" kargu-skill-max-file-bytes
   "body_chars" kargu-skill-max-chars "query" query))

(defun kargu-skill--catalog-inputs ()
  "Return the current editor catalog intent without filesystem IO."
  (kargu-skill--inputs (kargu-bridge--object "operation" "catalog")))

(defun kargu-skill--decode (result)
  "Check native RESULT's catalog projection before observing it."
  (unless (and (vectorp (gethash "skills" result))
               (<= (length (gethash "skills" result)) 128)
               (memq (gethash "truncated" result) '(t :json-false))
               (natnump (gethash "skipped" result)))
    (error "Invalid native skill catalog"))
  (seq-doseq (skill (gethash "skills" result))
    (unless (and (hash-table-p skill)
                 (stringp (gethash "name" skill))
                 (stringp (gethash "description" skill))
                 (stringp (gethash "path" skill)))
      (error "Invalid native skill metadata")))
  result)

(defun kargu-skill-refresh (callback)
  "Refresh this chat's native catalog and deliver a Result to CALLBACK.
Return a cancellable task; failure retains the last completed observation.
The current parent task owns preparation and Stop cancellation."
  (let* ((inputs (kargu-skill--catalog-inputs))
         ;; Copy nested settings before a core-startup yield can mutate them.
         (inputs (kargu-json-decode (json-serialize inputs :null-object :json-null :false-object :json-false)))
         (session (kargu-session-context))
         (owner-key (kargu-skill--owner-key))
         (intent (list nil))
         (parent kargu-async--current-task))
    (when (and (or (null parent)
                   (and (kargu-async-pending-p parent)
                        (or (null (kargu-async-task-deadline parent))
                            (> (kargu-async-task-deadline parent) (float-time)))))
               (or (null kargu-execution--current)
                   (kargu-execution-live-p kargu-execution--current)))
      (setq kargu-skill--intent intent))
    (kargu-bridge-read-task
     (lambda (result)
       (cond
        ((not (and (eq intent kargu-skill--intent)
                   (eq session (kargu-session-context))
                   (equal owner-key (kargu-skill--owner-key))
                   (kargu-skill--same-inputs-p inputs (kargu-skill--catalog-inputs))))
         (funcall callback (kargu-err "Skill discovery owner or intent changed" :stale)))
        ((stringp result) (funcall callback (kargu-err result :skills-unavailable)))
        (t
         (setq kargu-skill--cache (list :owner-key owner-key :session session :view result))
         (funcall callback (kargu-ok (gethash "text" result))))))
     inputs #'kargu-bridge-skills #'kargu-skill--decode)))

(defun kargu-skill--view ()
  "Return the current session's completed view; never start IO or a core."
  (when (and (eq (plist-get kargu-skill--cache :session) (kargu-session-context))
             (equal (plist-get kargu-skill--cache :owner-key) (kargu-skill--owner-key)))
    (plist-get kargu-skill--cache :view)))

(defun kargu-skill-list ()
  "Return detached metadata plists from the last completed native catalog.
Call `kargu-skill-refresh' to discover changes; bodies are loaded separately."
  (when-let* ((view (kargu-skill--view)))
    (mapcar (lambda (s) (list :name (copy-sequence (gethash "name" s))
                              :description (copy-sequence (gethash "description" s))
                              :path (copy-sequence (gethash "path" s))))
            (append (gethash "skills" view) nil))))

(defun kargu-skill-format-catalog ()
  "Return the completed native prompt catalog, or nil; this is memory-only."
  (when-let* ((view (kargu-skill--view)))
    (copy-sequence (gethash "text" view))))

(defun kargu-skill-load (name &optional callback)
  "Load skill NAME through Rust into CALLBACK, returning an owned task.
Without CALLBACK return an explicit error; never wait or read files in Lisp."
  (if (not callback)
      "ERROR: skill loading runs asynchronously; provide a callback"
    (let* ((query (kargu-bridge--object "operation" "load" "name" name))
           (inputs (kargu-json-decode
                    (json-serialize (kargu-skill--inputs query) :null-object :json-null :false-object :json-false))))
      (kargu-bridge-read-task
       callback inputs #'kargu-bridge-skills
       (lambda (result)
         (unless (kargu-skill--same-inputs-p inputs (kargu-skill--inputs (gethash "query" inputs)))
           (error "Skill discovery owner or settings changed"))
         (gethash "text" result))))))

(defun kargu-skill-register-tools ()
  "Register the asynchronous skill tool with the common tool gate."
  (kargu-register-tool
   "skill"
   "Load a named skill's instructions. Use when the task matches an available_skills entry."
   '(("type" . "object")
     ("properties" . (("name" . (("type" . "string")
                                 ("description" . "Skill name from available_skills.")))))
     ("required" . ["name"]))
   (lambda (args &optional callback)
     (kargu-skill-load (kargu--tool-arg args "name") callback))))

(provide 'kargu/tools/skill)
;;; skill.el ends here
