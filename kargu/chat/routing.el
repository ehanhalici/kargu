;;; routing.el --- Project-aware chat buffer lookup -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Find existing chat buffers by project, never by a globally fixed name.

;;; Code:

(require 'cl-lib)
(require 'kargu/permission/guards)

(declare-function kargu-session-context "kargu/core/session" (&optional buffer))
(declare-function kargu-session-id "kargu/core/session" (&optional session))
(declare-function kargu-application-context "kargu/application/coordinator" ())

(defvar-local kargu-chat--project-root nil
  "Canonical project root owning the current chat buffer.")

(defvar-local kargu-chat--session-id nil
  "Buffer-local session identifier.")

(cl-defstruct (kargu-chat-handle-store (:constructor kargu-chat-handle-store--create))
  "Opaque native handles, committed DTO revision, and buffer epoch for one chat buffer."
  (buffer nil :read-only t)
  (token (gensym "kargu-chat-buffer-") :read-only t)
  (application-handle nil)
  (session-handle nil)
  (run-handle nil)
  (edit-handle nil)
  (last-dto nil)
  (last-revision 0))

(defvar-local kargu-chat--handle-store nil
  "Buffer-local handle store capturing native handles, run states and DTOs.")

(defun kargu-chat-handle-store (&optional buffer)
  "Return the handle store for BUFFER (default: current buffer).
Lazily creates an isolated store bound to the buffer's exact identity."
  (let ((buf (or buffer (current-buffer))))
    (unless (buffer-live-p buf)
      (user-error "Kargu: buffer is not live"))
    (with-current-buffer buf
      (unless (and kargu-chat--handle-store
                   (eq (kargu-chat-handle-store-buffer kargu-chat--handle-store) buf))
        (setq-local kargu-chat--handle-store
                    (kargu-chat-handle-store--create
                     :buffer buf
                     :application-handle (and (fboundp 'kargu-application-context)
                                              (kargu-application-context))
                     :session-handle (and (fboundp 'kargu-session-context)
                                          (kargu-session-context buf)))))
      kargu-chat--handle-store)))

(defun kargu-chat-handle-valid-p (store &optional buffer)
  "Return non-nil if STORE is still valid for BUFFER (or STORE's buffer).
Rejects dead buffers, token mismatches, and reincarnated buffer names."
  (let ((buf (or buffer (and store (kargu-chat-handle-store-buffer store)))))
    (and (buffer-live-p buf)
         store
         (eq buf (kargu-chat-handle-store-buffer store))
         (with-current-buffer buf
           (and (eq store kargu-chat--handle-store)
                (eq (kargu-chat-handle-store-token store)
                    (and kargu-chat--handle-store
                         (kargu-chat-handle-store-token kargu-chat--handle-store))))))))

(defun kargu-chat-run-handle (&optional buffer)
  "Return the active run handle of BUFFER, or nil when idle."
  (when-let* ((buf (or buffer (current-buffer)))
              ((buffer-live-p buf)))
    (with-current-buffer buf
      (and kargu-chat--handle-store
           (kargu-chat-handle-store-run-handle kargu-chat--handle-store)))))

(defun kargu-chat-set-run-handle (handle &optional buffer)
  "Set the active run HANDLE for BUFFER."
  (let ((buf (or buffer (current-buffer))))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (let ((store (kargu-chat-handle-store buf)))
          (setf (kargu-chat-handle-store-run-handle store) handle))))))

(defun kargu-chat-edit-handle (&optional buffer)
  "Return the active edit handle of BUFFER, or nil when none."
  (when-let* ((buf (or buffer (current-buffer)))
              ((buffer-live-p buf)))
    (with-current-buffer buf
      (and kargu-chat--handle-store
           (kargu-chat-handle-store-edit-handle kargu-chat--handle-store)))))

(defun kargu-chat-set-edit-handle (handle &optional buffer)
  "Set the active edit HANDLE for BUFFER."
  (let ((buf (or buffer (current-buffer))))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (let ((store (kargu-chat-handle-store buf)))
          (setf (kargu-chat-handle-store-edit-handle store) handle))))))

(defun kargu-chat-running-p (&optional buffer)
  "Return non-nil when BUFFER has an active run in flight."
  (not (null (kargu-chat-run-handle buffer))))

(defun kargu-chat-last-dto (&optional buffer)
  "Return (REVISION . DTO) for the last committed state of BUFFER."
  (when-let* ((buf (or buffer (current-buffer)))
              ((buffer-live-p buf)))
    (with-current-buffer buf
      (when-let* ((store (kargu-chat-handle-store buf)))
        (cons (kargu-chat-handle-store-last-revision store)
              (kargu-chat-handle-store-last-dto store))))))

(defun kargu-chat-update-dto (dto revision &optional buffer)
  "Store committed DTO and monotonically advance REVISION for BUFFER.
Rejects stale or non-monotonic updates."
  (let ((buf (or buffer (current-buffer))))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (let ((store (kargu-chat-handle-store buf)))
          (when (and (numberp revision)
                     (> revision (kargu-chat-handle-store-last-revision store)))
            (setf (kargu-chat-handle-store-last-dto store) dto)
            (setf (kargu-chat-handle-store-last-revision store) revision)
            t))))))

(defun kargu-chat-find-buffer-by-session (session-id &optional project-root)
  "Find an existing chat buffer matching SESSION-ID and optional PROJECT-ROOT."
  (let ((root (and project-root
                   (file-name-as-directory (file-truename project-root)))))
    (cl-find-if
     (lambda (buf)
       (with-current-buffer buf
         (and (derived-mode-p 'kargu-chat-mode)
              (equal session-id (or kargu-chat--session-id
                                    (and (fboundp 'kargu-session-id) (kargu-session-id))))
              (or (null root)
                  (equal root (or kargu-chat--project-root
                                  (kargu-permission-project-root buf)))))))
     (buffer-list))))

(defvar kargu-chat-buffer-name)

(defun kargu-chat-find-buffer (&optional project-root)
  "Return an existing chat for PROJECT-ROOT, or nil without a matching chat.
Default to the caller's current project.  Never create a buffer or choose
an unrelated project's default-named chat."
  (let ((root (file-name-as-directory
               (file-truename (or project-root (kargu-permission-project-root))))))
    (cl-find-if
     (lambda (buffer)
       (with-current-buffer buffer
         (and (derived-mode-p 'kargu-chat-mode)
              (equal root (or kargu-chat--project-root
                              (kargu-permission-project-root buffer))))))
     (buffer-list))))

(defun kargu-chat-restore-target (root &optional target)
  "Resolve chat ROOT's restore TARGET without choosing another project.
An explicit live TARGET may be uninitialized, but an existing chat must
already belong to ROOT.  With no target, reuse a matching chat or create
a uniquely named buffer; never reuse a foreign default-named buffer."
  (when target
    (unless (buffer-live-p target) (user-error "Kargu: restore target is not live"))
    (unless (with-current-buffer target
              (or (not (derived-mode-p 'kargu-chat-mode))
                  (equal root (file-name-as-directory
                               (file-truename (or kargu-chat--project-root
                                                  (kargu-permission-project-root)))))))
      (user-error "Kargu: restore target belongs to another project")))
  (or target
      (and (derived-mode-p 'kargu-chat-mode)
           (equal root kargu-chat--project-root) (current-buffer))
      (kargu-chat-find-buffer root)
      (progn
        (unless (boundp 'kargu-chat-buffer-name)
          (user-error "Kargu: chat UI is unavailable for session restore"))
        (generate-new-buffer kargu-chat-buffer-name))))

(provide 'kargu/chat/routing)

;;; routing.el ends here
