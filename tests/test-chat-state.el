;;; test-chat-state.el --- Passive chat state observers -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Mode views observe committed state, preserve editing context and own no
;; global buffer registry.  The composition root installs the subscription.

;;; Code:

(require 'ert)
(require 'tests/test-helpers)
(require 'kargu/chat)

(defmacro kargu-chat-state-test--with-views (&rest body)
  "Run BODY with two initialized chat buffers `a' and `b'."
  (declare (indent 0))
  `(let ((a (generate-new-buffer " *kargu-state-view-a*"))
         (b (generate-new-buffer " *kargu-state-view-b*"))
         (kargu-session-auto-save nil)
         (kargu--loop-run nil)
         (kargu-state-mode-hook '(kargu-chat-refresh-mode)))
     (unwind-protect
         (cl-letf (((symbol-function 'kargu-api-prefetch-models) #'ignore))
           (dolist (view (list a b))
             (with-current-buffer view
               (kargu-chat-mode)
               (insert "transcript\n")
               (kargu-chat--ensure-prompt)
               (goto-char (point-max))
               (insert "draft")))
           ,@body)
       (when (buffer-live-p a) (kill-buffer a))
       (when (buffer-live-p b) (kill-buffer b)))))

(ert-deftest kargu-chat-state-mode-notification-preserves-editing-test ()
  "Only the owner's view updates, preserving point, draft and narrowing."
  (kargu-chat-state-test--with-views
    (dolist (view (list a b))
      (with-current-buffer view (goto-char 2) (narrow-to-region 1 3)))
    (with-current-buffer b
      (kargu-state-set-mode 'plan)
      (should (eq (current-buffer) b)))
    (dolist (view (list a b))
      (with-current-buffer view
        (should (= (point) 2))
        (should (= (point-min) 1))
        (should (= (point-max) 3))
        (widen)
        (should (string-search (if (eq view b) "mode: [PLAN]" "mode: [ASK]")
                               (buffer-string)))
        (should (equal (kargu-chat--input-text) "draft"))))))

(ert-deftest kargu-chat-state-broken-view-does-not-block-another-test ()
  "A view failure cannot prevent another footer or the committed mode."
  (kargu-chat-state-test--with-views
    (let ((refresh (symbol-function 'kargu-chat-refresh-footer)))
      (cl-letf (((symbol-function 'kargu-chat-list-buffers) (lambda () (list a b)))
                ((symbol-function 'kargu-chat-refresh-footer)
                 (lambda ()
                   (if (eq (current-buffer) a) (error "Broken view")
                     (funcall refresh)))))
        (with-current-buffer a
          (kargu-state-set-mode 'plan)
          (should (eq (kargu-state-mode) 'plan)))
        (with-current-buffer b
          (kargu-state-set-mode 'plan)
          (should (string-search "mode: [PLAN]" (buffer-string)))
          (should (equal (kargu-chat--input-text) "draft")))))))

(ert-deftest kargu-chat-state-list-is-derived-and-live-unload-is-refused-test ()
  "No cached global list can retain closed views or outlive the UI."
  (kargu-chat-state-test--with-views
    (should-not (boundp 'kargu-chat-buffers))
    (should (memq a (kargu-chat-list-buffers)))
    (should (memq b (kargu-chat-list-buffers)))
    (should-error (kargu/chat-unload-function) :type 'user-error)
    (kill-buffer a)
    (should-not (memq a (kargu-chat-list-buffers)))
    (should (memq b (kargu-chat-list-buffers)))))

(provide 'tests/test-chat-state)
;;; test-chat-state.el ends here
