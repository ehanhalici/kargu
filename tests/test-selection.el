;;; test-selection.el --- Owned selection contracts -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Native configuration, UI continuations and state observers consume the
;; same session-owned selection.  No chat snapshot writes back into it.

;;; Code:

(require 'ert)
(require 'tests/test-helpers)
(require 'kargu/selection)
(require 'kargu/chat/select)

(ert-deftest kargu-selection-values-are-owned-and-earlier-values-stable-test ()
  "Two owners and a captured immutable value cannot overwrite one another."
  (let (a-frame before)
    (with-temp-buffer
      (setq a-frame (kargu-session-context))
      (kargu-selection-update :provider "alpha" :model "a" :effort 'low)
      (setq before (kargu-selection-context))
      (should-error (kargu-selection-update :provider "beta" :model 3))
      (should (eq before (kargu-selection-context)))
      (with-temp-buffer
        (kargu-selection-update :provider "beta" :model "b" :effort 'high)
        (should-error (kargu-selection-update :model "wrong owner" :session a-frame)
                      :type 'user-error)
        (should (equal (kargu-selection-model) "b")))
      (should (eq before (kargu-selection-context)))
      (kargu-selection-update :model "next")
      (should (equal (kargu-selection-model-value before) "a"))
      (should (equal (kargu-selection-provider) "alpha")))))

(ert-deftest kargu-selection-notifications-see-an-atomic-tuple-test ()
  "Each field listener sees the entire provider/model/effort commit."
  (with-temp-buffer
    (let ((kargu-state-change-hook nil) events)
      (add-hook 'kargu-state-change-hook
                (lambda (key _)
                  (push key events)
                  (should (equal (kargu-selection-provider) "p"))
                  (should (equal (kargu-selection-model) "m"))
                  (should (eq (kargu-selection-effort) 'low))))
      (kargu-selection-update :provider "p" :model "m" :effort 'low)
      (should (equal (nreverse events) '(:provider :model :reasoning-effort))))))

(ert-deftest kargu-selection-reentrant-replacement-stops-old-notifications-test ()
  "A listener's replacement frame never receives remaining old-field events."
  (with-temp-buffer
    (let ((kargu-state-change-hook nil) events)
      (add-hook 'kargu-state-change-hook
                (lambda (key _)
                  (push key events)
                  (when (eq key :provider) (kargu-session-clear))))
      (should-not (kargu-selection-update :provider "p" :model "m" :effort 'high))
      (should (equal events '(:provider)))
      (should-not (kargu-selection-provider))
      (should-not (kargu-selection-model)))))

(ert-deftest kargu-selection-live-work-refuses-change-and-reset-test ()
  "Active native work prevents partial changes, including direct state reset."
  (with-temp-buffer
    (kargu-selection-update :provider "p" :model "m")
    (let ((before (kargu-selection-context))
          (state (copy-tree kargu--state-store)))
      (dolist (kind '(request run))
        (let ((kargu--busy (eq kind 'request))
              (kargu--loop-run (and (eq kind 'run) (list :state 'request)))
              (kargu-temperature 0.7) (kargu-max-tokens 123)
              (kargu-thinking-budget 456) (kargu-stream nil))
          (should-error (kargu-selection-update :provider "other") :type 'user-error)
          (should-error (kargu-state-reset) :type 'user-error)
          (should-error (kargu-tune-reset-defaults) :type 'user-error)
          (should (= kargu-temperature 0.7))
          (should (= kargu-max-tokens 123))
          (should (= kargu-thinking-budget 456))
          (should-not kargu-stream)
          (should (eq before (kargu-selection-context)))
          (should (equal state kargu--state-store)))))))

(ert-deftest kargu-selection-reasoning-default-off-and-api-names-stay-distinct-test ()
  "A local off does not modify configuration or collide with an API name."
  (with-temp-buffer
    (let ((kargu-reasoning-effort 'high))
      (should (eq (kargu-selection-effort) 'high))
      (kargu-state-set-reasoning-effort nil)
      (should-not (kargu-selection-effort))
      (should (eq kargu-reasoning-effort 'high))
      (kargu-state-set-reasoning-effort 'none)
      (should (equal (kargu-reasoning-effort-level) "none"))
      (kargu-state-set-reasoning-effort :inherit)
      (should (equal (kargu-reasoning-effort-level) ":inherit"))
      (kargu-selection-update :effort kargu-selection-default-effort)
      (should (eq (kargu-selection-effort) 'high)))))

(ert-deftest kargu-selection-obsolete-list-cannot-apply-to-new-state-test ()
  "A list opened before a frame or selection change cannot apply afterwards."
  (dolist (replacement '(selection session))
    (with-temp-buffer
      (kargu-selection-update :provider "p" :model "before")
      (cl-letf (((symbol-function 'kargu--completing-read-with-company)
                 (lambda (&rest _)
                   (when (eq replacement 'session) (kargu-session-clear))
                   (kargu-selection-update :provider "p" :model "newer")
                   "old-list-choice")))
        (should-error
         (kargu-api-select 'model '("old-list-choice") nil
                           (lambda (model) (kargu-state-set-model model)))
         :type 'user-error)
        (should (equal (kargu-selection-model) "newer"))))))

(ert-deftest kargu-selection-late-catalog-does-not-open-obsolete-picker-test ()
  "Same-provider replacements invalidate catalog results without UI effects."
  (dolist (replacement '(selection session))
    (with-temp-buffer
      (let ((kargu--live-models-cache (make-hash-table :test #'equal)) held opened)
        (kargu-selection-update :provider "p" :model "before")
        (cl-letf (((symbol-function 'kargu-api-fetch-model-ids)
                   (lambda (_provider callback &optional _) (setq held callback)))
                  ((symbol-function 'kargu-chat--open-model-selector)
                   (lambda (&rest _) (setq opened t))))
          (kargu-chat-select-model-company)
          (when (eq replacement 'session) (kargu-session-clear))
          (kargu-selection-update :provider "p" :model "newer")
          (with-temp-buffer (funcall held '("old-catalog")))
          (should-not opened)
          (should (equal (kargu-selection-model) "newer")))))))

(ert-deftest kargu-selection-explicit-provider-model-commit-is-one-event-batch-test ()
  "Native provider UI commits no cached model before clearing it again."
  (with-temp-buffer
    (let ((kargu-state-change-hook nil) events)
      (cl-letf (((symbol-function 'kargu-api-prefetch-models) #'ignore)
                ((symbol-function 'kargu--provider-plist)
                 (lambda (&optional _) '(:model "configured-model"))))
        (add-hook 'kargu-state-change-hook
                  (lambda (key _) (push key events)
                    (should (equal (kargu-selection-provider) "p"))
                    (should-not (kargu-selection-model))))
        (kargu-set-provider "p" t)
        (should (equal events '(:reasoning-effort :provider)))))))

(ert-deftest kargu-selection-superseded-commit-does-not-continue-ui-chain-test ()
  "A reset during notification cannot open a next picker for the new frame."
  (dolist (action '(provider model effort))
    (with-temp-buffer
      (let ((kargu-state-change-hook nil) continued prefetched)
        (add-hook 'kargu-state-change-hook (lambda (&rest _) (kargu-session-clear)))
        (cl-letf (((symbol-function 'kargu-api-select--continue)
                   (lambda (_) (setq continued t)))
                  ((symbol-function 'kargu-api-prefetch-models)
                   (lambda (&rest _) (setq prefetched t))))
          (pcase action
            ('provider (kargu-api-select--apply-provider "p"))
            ('model (kargu-api-select--apply-model "m" "p"))
            ('effort (kargu-api-select--apply-effort "low")))
          (should-not continued)
          (should-not prefetched)
          (should-not (kargu-selection-provider))
          (should-not (kargu-selection-model)))))))

(ert-deftest kargu-selection-service-candidate-and-membership-validation-test ()
  "Candidate normalization and membership checks work without the chat UI."
  (should (equal (kargu-selection-normalize-candidates '("a" "" b)) '("a" "b")))
  (should (equal (kargu-selection-validate-member "  a " '("a" "b") 'model) "a"))
  (should-error (kargu-selection-validate-member "c" '("a" "b") 'model)
                :type 'user-error)
  (should (equal (kargu-selection-effort-candidates '("low" "off" "high" "low"))
                 '("off" "low" "high")))
  (let ((table (make-hash-table :test #'equal)))
    (should-not (kargu-selection-models-known-p "p" nil table))
    (should (equal (kargu-selection-model-candidates "p" nil '("fallback") table)
                   '("fallback")))
    (puthash "p" '() table)
    (should (kargu-selection-models-known-p "p" nil table))
    (should-not (kargu-selection-model-candidates "p" '("stale") '("fallback") table))))

(ert-deftest kargu-selection-late-catalog-respects-focus-and-draft-changes-test ()
  "Delayed catalog results do not open a popup if draft, point or focus changed."
  (dolist (change '(draft point window-buffer))
    (with-temp-buffer
      (insert "prompt: ")
      (let ((kargu--live-models-cache (make-hash-table :test #'equal))
            (orig-win-buf (window-buffer (selected-window)))
            held opened)
        (kargu-selection-update :provider "p" :model "before")
        (unwind-protect
            (cl-letf (((symbol-function 'kargu-api-fetch-model-ids)
                       (lambda (_provider callback &optional _) (setq held callback)))
                      ((symbol-function 'kargu-chat--open-model-selector)
                       (lambda (&rest _) (setq opened t))))
              (kargu-chat-select-model-company)
              (pcase change
                ('draft (save-excursion (insert "user typing")))
                ('point (goto-char (point-min)))
                ('window-buffer (set-window-buffer (selected-window) (current-buffer))))
              (funcall held '("m1"))
              (should-not opened)
              (should (equal (kargu-selection-model) "before")))
          (when (buffer-live-p orig-win-buf)
            (set-window-buffer (selected-window) orig-win-buf)))))))

(provide 'tests/test-selection)
;;; test-selection.el ends here
