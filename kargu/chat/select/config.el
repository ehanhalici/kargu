;;; config.el --- Buffer-owned configuration refresh for selectors -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Explicit selector entry points refresh through the bounded config worker.
;; Passive readers stay IO-free.  Closing or replacing a view cancels only
;; that view's refresh, never another application's preparation or worker.

;;; Code:

(require 'cl-lib)
(require 'kargu/config/service)

(defvar-local kargu-select-config--task nil
  "The current view's pending selector configuration refresh.")

(defvar-local kargu-select-config--generation 0
  "Generation refusing late callbacks from a superseded selector refresh.")

(defun kargu-select-config-refresh (callback)
  "Refresh this view's configuration asynchronously, delivering CALLBACK once.
Return the cancellable task.  CALLBACK receives the configuration Result;
its consumer must check captured session, selection and focus before UI work."
  (when kargu-select-config--task (kargu-async-cancel kargu-select-config--task))
  (let* ((origin (current-buffer))
         (application-owner kargu-application-owner)
         (generation (cl-incf kargu-select-config--generation))
         task
         (cancel (lambda () (when task (kargu-async-cancel task)))))
    (add-hook 'kill-buffer-hook cancel nil t)
    (add-hook 'change-major-mode-hook cancel nil t)
    (condition-case nil
        (progn
          (setq task (kargu-config-refresh-async
                      (lambda (result)
                        (when (buffer-live-p origin)
                          (with-current-buffer origin
                            (when (and (= generation kargu-select-config--generation)
                                       (eq application-owner kargu-application-owner))
                              (funcall callback result)))))
                      :owner nil :parent nil))
          ;; An injected or already-ready adapter may complete synchronously.
          (when (and (= generation kargu-select-config--generation)
                     (kargu-async-pending-p task))
            (setq kargu-select-config--task task))
          (kargu-async-add-cleanup
           task (lambda ()
                  (when (buffer-live-p origin)
                    (with-current-buffer origin
                      (remove-hook 'kill-buffer-hook cancel t)
                      (remove-hook 'change-major-mode-hook cancel t)
                      (when (eq kargu-select-config--task task)
                        (setq kargu-select-config--task nil))))))
          task)
      (error
       (funcall cancel)
       (remove-hook 'kill-buffer-hook cancel t)
       (remove-hook 'change-major-mode-hook cancel t)
       (user-error "Kargu: configuration refresh could not start")))))

(provide 'kargu/chat/select/config)
;;; config.el ends here
