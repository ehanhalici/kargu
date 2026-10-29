;;; review.el --- Owned native batch review presentation -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Each file is reviewed before the final exact-revision batch decision.

;;; Code:

(require 'kargu/async)
(require 'kargu/bridge/edit)
(require 'ediff)

(defvar kargu-diff-ediff-window-setup-function)
(defvar kargu-diff-ediff-split-window-function)

(cl-defstruct (kargu-bridge-edit-batch-review-state
               (:constructor kargu-bridge-edit-batch-review--state))
  "One review's exact native owner and remaining presentation sequence."
  artifact files edit revision task callback (index 0))

(cl-defstruct (kargu-bridge-edit-batch-review-screen
               (:constructor kargu-bridge-edit-batch-review--screen))
  "Only the Ediff resources owned by one file presentation."
  state file original shadow control window-config owned-window-config quit-hook kill-hook completed)

(defun kargu-bridge-edit-batch-review--decide (state decision)
  "Submit DECISION for STATE's current exact native revision."
  (kargu-bridge-edit-decision
   (kargu-bridge-edit-batch-review-state-artifact state)
   :edit-id (kargu-bridge-edit-batch-review-state-edit state)
   :revision (kargu-bridge-edit-batch-review-state-revision state)
   :decision decision :callback
   (kargu-async-wrap (kargu-bridge-edit-batch-review-state-task state)
                     (kargu-bridge-edit-batch-review-state-callback state))))

(defun kargu-bridge-edit-batch-review--dispose (screen)
  "Close only SCREEN's owned resources without completing another review."
  (let* ((control (kargu-bridge-edit-batch-review-screen-control screen))
         (original (kargu-bridge-edit-batch-review-screen-original screen))
         (shadow (kargu-bridge-edit-batch-review-screen-shadow screen))
         (wconfig (kargu-bridge-edit-batch-review-screen-window-config screen))
         (owned (kargu-bridge-edit-batch-review-screen-owned-window-config screen))
         (frame (and (window-configuration-p wconfig) (window-configuration-frame wconfig)))
         (restore-wconfig (and (frame-live-p frame) (window-configuration-p owned)
                               (window-configuration-equal-p (current-window-configuration frame) owned))))
    (when (buffer-live-p control)
      (with-current-buffer control
        (remove-hook 'ediff-quit-hook (kargu-bridge-edit-batch-review-screen-quit-hook screen) t)
        (remove-hook 'kill-buffer-hook (kargu-bridge-edit-batch-review-screen-kill-hook screen) t)
        (unless (kargu-bridge-edit-batch-review-screen-completed screen)
          (setf (kargu-bridge-edit-batch-review-screen-completed screen) t)
          (condition-case nil
              (let ((ediff-keep-variants t)) (ediff-really-quit nil))
            (error (when (buffer-live-p control) (kill-buffer control)))))))
    (dolist (buffer (list original shadow))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer (set-buffer-modified-p nil))
        (kill-buffer buffer)))
    (when (and restore-wconfig (frame-live-p frame))
      (set-window-configuration wconfig))))

(defun kargu-bridge-edit-batch-review--closed (screen &optional abandoned)
  "Observe SCREEN's actual proposal at quit, or interrupt if ABANDONED."
  (unless (kargu-bridge-edit-batch-review-screen-completed screen)
    (setf (kargu-bridge-edit-batch-review-screen-completed screen) t)
    (let* ((state (kargu-bridge-edit-batch-review-screen-state screen))
           (task (kargu-bridge-edit-batch-review-state-task state))
           (shadow (kargu-bridge-edit-batch-review-screen-shadow screen))
           (text (and (not abandoned) (buffer-live-p shadow)
                      (with-current-buffer shadow (buffer-string)))))
      (kargu-bridge-edit-batch-review--dispose screen)
      ;; Let Ediff finish its own cleanup before opening another presentation.
      (let ((timer (run-at-time
                    0 nil (kargu-async-wrap
                           task (lambda () (kargu-bridge-edit-batch-review--advance state text))))))
        (kargu-async-add-cleanup task (lambda () (cancel-timer timer)))))))

(defun kargu-bridge-edit-batch-review--advance (state text)
  "Review TEXT from STATE's current file before moving to the next."
  (let* ((file (car (kargu-bridge-edit-batch-review-state-files state)))
         (base (plist-get file :base)) (proposed (plist-get file :proposed)))
    (cond
     ((null text) (kargu-bridge-edit-batch-review--decide state 'interrupt))
     ((and (not (equal base proposed)) (equal text base))
      (kargu-bridge-edit-batch-review--decide state 'reject))
     ((equal text proposed) (kargu-bridge-edit-batch-review--continue state))
     ((equal (gethash "operation" (plist-get file :view)) "delete")
      (kargu-bridge-edit-batch-review--decide state 'reject))
     (t
      (kargu-bridge-edit-revise
       (kargu-bridge-edit-batch-review-state-artifact state)
       :edit-id (kargu-bridge-edit-batch-review-state-edit state)
       :revision (kargu-bridge-edit-batch-review-state-revision state)
       :file-index (kargu-bridge-edit-batch-review-state-index state) :new-text text
       :callback (kargu-async-wrap
                  (kargu-bridge-edit-batch-review-state-task state)
                  (lambda (value failure)
                    (if failure
                        (funcall (kargu-bridge-edit-batch-review-state-callback state) nil failure)
                      (setf (kargu-bridge-edit-batch-review-state-revision state) (gethash "revision" value)
                            (plist-get file :proposed) text)
                      (kargu-bridge-edit-batch-review--continue state)))))))))

(defun kargu-bridge-edit-batch-review--continue (state)
  "Advance STATE after its current file has been accepted or revised."
  (setf (kargu-bridge-edit-batch-review-state-files state)
        (cdr (kargu-bridge-edit-batch-review-state-files state))
        (kargu-bridge-edit-batch-review-state-index state)
        (1+ (kargu-bridge-edit-batch-review-state-index state)))
  (kargu-bridge-edit-batch-review--next state))

(defun kargu-bridge-edit-batch-review--next (state)
  "Present STATE's next file, or decide only after all files are reviewed."
  (if (null (kargu-bridge-edit-batch-review-state-files state))
      (kargu-bridge-edit-batch-review--decide state 'accept)
    (let* ((file (car (kargu-bridge-edit-batch-review-state-files state)))
           (task (kargu-bridge-edit-batch-review-state-task state))
           (original (generate-new-buffer " *kargu-native-base*"))
           (shadow (generate-new-buffer " *kargu-native-proposal*"))
           (screen (kargu-bridge-edit-batch-review--screen
                    :state state :file file :original original :shadow shadow
                    :window-config (current-window-configuration))))
      (with-current-buffer original (insert (plist-get file :base)) (setq buffer-read-only t))
      (with-current-buffer shadow (insert (plist-get file :proposed)))
      (kargu-async-add-cleanup task (lambda () (kargu-bridge-edit-batch-review--dispose screen)))
      (condition-case nil
          (let* ((ediff-window-setup-function
                  (if (boundp 'kargu-diff-ediff-window-setup-function)
                      (or kargu-diff-ediff-window-setup-function #'ediff-setup-windows-plain)
                    #'ediff-setup-windows-plain))
                 (ediff-split-window-function
                  (if (boundp 'kargu-diff-ediff-split-window-function)
                      (or kargu-diff-ediff-split-window-function #'split-window-horizontally)
                    #'split-window-horizontally))
                 (control (ediff-buffers original shadow)))
            (unless (buffer-live-p control) (error "Ediff did not create a review control"))
            (setf (kargu-bridge-edit-batch-review-screen-owned-window-config screen)
                  (current-window-configuration
                   (window-configuration-frame (kargu-bridge-edit-batch-review-screen-window-config screen))))
            (setf (kargu-bridge-edit-batch-review-screen-control screen) control
                  (kargu-bridge-edit-batch-review-screen-quit-hook screen)
                  (lambda () (kargu-bridge-edit-batch-review--closed screen))
                  (kargu-bridge-edit-batch-review-screen-kill-hook screen)
                  (lambda () (kargu-bridge-edit-batch-review--closed screen t)))
            (with-current-buffer control
              (add-hook 'ediff-quit-hook (kargu-bridge-edit-batch-review-screen-quit-hook screen) nil t)
              (add-hook 'kill-buffer-hook (kargu-bridge-edit-batch-review-screen-kill-hook screen) nil t)))
        ((error quit)
         (setf (kargu-bridge-edit-batch-review-screen-completed screen) t)
         (kargu-bridge-edit-batch-review--dispose screen)
         (kargu-bridge-edit-batch-review--decide state 'interrupt))))))

(cl-defun kargu-bridge-edit-batch-review (artifact files &key edit revision task callback)
  "Review all FILES in ARTIFACT under TASK and deliver CALLBACK.
EDIT and REVISION identify the exact pending native approval."
  (let ((state (kargu-bridge-edit-batch-review--state
                :artifact artifact :files files :edit edit :revision revision :task task :callback callback)))
    (if noninteractive (kargu-bridge-edit-batch-review--decide state 'interrupt)
      (kargu-bridge-edit-batch-review--next state))))

(provide 'kargu/bridge/edit/batch/review)
;;; review.el ends here
