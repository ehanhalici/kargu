;;; tests/test-chat.el --- Tests for the chat buffer, footer and @ completion -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'ert)
(require 'cl-lib)
(require 'tests/test-helpers)
(require 'kargu/core)
(require 'kargu/api)
(require 'kargu/chat)
(require 'kargu/chat/prompt)
(require 'kargu/chat/header)
(require 'kargu/chat/complete)
(require 'kargu/loop)
(require 'kargu/providers/catalog)
(require 'kargu/tools/lsp)

(declare-function kargu-chat--tool-heading "kargu/chat/render" (name arguments))
(declare-function kargu-chat--result-summary "kargu/chat/render" (result))

(ert-deftest kargu-chat-buffer-lookup-is-project-aware-test ()
  "Source-buffer commands target their project, not the first named chat."
  (let* ((kargu-chat-buffer-name (generate-new-buffer-name "*kargu-route-test*"))
         (first (generate-new-buffer kargu-chat-buffer-name))
         (second (generate-new-buffer kargu-chat-buffer-name))
         (root (kargu-permission-project-root))
         (other (file-name-as-directory (expand-file-name "other" root))))
    (unwind-protect
        (progn
          (with-current-buffer first
            (setq major-mode 'kargu-chat-mode kargu-chat--project-root root))
          (with-current-buffer second
            (setq major-mode 'kargu-chat-mode kargu-chat--project-root other))
          (with-temp-buffer
            (let ((kargu-permission--override-root other) (kargu--loop-run nil))
              (should (eq (kargu-chat-output-buffer) second))
              (should (eq (kargu-api-select--chat-buffer) second)))
            (let ((kargu-permission--override-root
                   (file-name-as-directory (expand-file-name "absent" root))))
              (should-not (kargu-chat-find-buffer))))
          (let ((kargu--loop-run (list :chat-buffer first))
                (kargu-permission--override-root other))
            (should (eq (kargu-chat-output-buffer) first))
            (should (eq (kargu-api-select--chat-buffer) second))))
      (kill-buffer first)
      (kill-buffer second))))

(ert-deftest kargu-chat-inline-thoughts-preserve-match-data-test ()
  "Multiple inline thought blocks render in order without leaking matches."
  (with-temp-buffer
    (let ((kargu-chat--streamed-text nil)
          (kargu-chat--in-thought nil)
          (kargu-chat--preamble-dropped nil)
          chunks)
      (string-match "value" "saved value")
      (let ((saved (match-data)))
        (cl-letf (((symbol-function 'kargu-chat-output-buffer) #'current-buffer)
                  ((symbol-function 'kargu-chat-insert)
                   (lambda (text &optional face)
                     (string-match "changed" "changed")
                     (push (cons text face) chunks))))
          (kargu-chat--on-delta "A<think>B</think>C<think>D</think>E"))
        (should (equal (match-data) saved)))
      (should (equal (nreverse chunks)
                     '(("A") ("B" . kargu-chat-thought) ("C")
                       ("D" . kargu-chat-thought) ("E"))))
      (should-not kargu-chat--in-thought))))

(ert-deftest kargu-chat-context-usage-footer-test ()
  "Test that context usage is accurately calculated and rendered."
  (kargu-model-set-metadata "gemini-2.5-flash" '(("context_length" . 1000000)))
  (let ((kargu--session-model "gemini-2.5-flash")
        (kargu--session (list :tokens 0 :turns 0 :last-prompt-tokens 32000)))
    (let ((info (kargu-session-context-info)))
      (should (= (plist-get info :used) 32000))
      (should (> (plist-get info :capacity) 0))
      (should (string-match-p "32.0k" (plist-get info :formatted)))
      (should (string-match-p "%" (plist-get info :formatted))))
    ;; Verify footer contains context info
    (let ((footer (kargu-chat--footer-string)))
      (should (string-match-p "ctx:" footer)))))

(ert-deftest kargu-chat-thought-tags-survive-every-chunk-boundary-test ()
  "Reasoning markers split at any byte preserve content and faces."
  (let ((text "A<think>B</think>C"))
    (dotimes (split (length text))
      (with-temp-buffer
        (let ((kargu-chat--streamed-text nil)
              (kargu-chat--in-thought nil)
              (kargu-chat--preamble-dropped nil))
          (cl-letf (((symbol-function 'kargu-chat-insert)
                     (lambda (value &optional face)
                       (insert (propertize value 'face face)))))
            (kargu-chat--stream-delta (substring text 0 split) nil)
            (kargu-chat--stream-delta (substring text split) nil)
            (kargu-chat-flush-stream))
          (should (equal (buffer-string) "ABC"))
          (should-not (get-text-property 1 'face))
          (should (eq (get-text-property 2 'face) 'kargu-chat-thought))
          (should-not (get-text-property 3 'face)))))))

(ert-deftest kargu-chat-trailing-thought-prefix-is-preserved-test ()
  "An incomplete marker at the end remains literal transcript text."
  (with-temp-buffer
    (let ((kargu-chat--streamed-text nil)
          (kargu-chat--in-thought nil)
          (kargu-chat--preamble-dropped nil))
      (cl-letf (((symbol-function 'kargu-chat-insert)
                 (lambda (text &optional _face) (insert text))))
        (kargu-chat--stream-delta "literal <thi" nil)
        (should (equal (buffer-string) "literal "))
        (kargu-chat-flush-stream)
        (should (equal (buffer-string) "literal <thi"))))))

(ert-deftest kargu-chat-project-buffer-does-not-overwrite-another-test ()
  "Opening another project preserves the first project's live chat."
  (let* ((temp (make-temp-file "kargu-project-chats-" t))
         (kargu-sessions-directory (expand-file-name "sessions" temp))
         (kargu-chat-buffer-name "*kargu-project-chats-test*")
         (kargu-session-auto-restore nil)
         (a (expand-file-name "a" temp))
         (b (expand-file-name "b" temp))
         first second)
    (unwind-protect
        (progn
          (make-directory a t)
          (make-directory b t)
          (cl-letf (((symbol-function 'kargu-chat-check-and-display-missing-tools) #'ignore))
            (setq first (kargu-chat--buffer a)
                  second (kargu-chat--buffer b)))
          (should-not (eq first second))
          (should (equal (buffer-local-value 'kargu-chat--project-root first)
                         (file-name-as-directory (file-truename a))))
          (should (equal (buffer-local-value 'kargu-chat--project-root second)
                         (file-name-as-directory (file-truename b)))))
      (when (buffer-live-p first) (kill-buffer first))
      (when (buffer-live-p second) (kill-buffer second))
      (delete-directory temp t))))

(ert-deftest kargu-chat-multiple-buffers-test ()
  "Test creating and switching multiple independent chat buffers."
  (let ((buf1 (get-buffer-create "*kargu-chat-test-1*"))
        (buf2 (get-buffer-create "*kargu-chat-test-2*")))
    (unwind-protect
        (progn
          (with-current-buffer buf1
            (kargu-chat-mode))
          (with-current-buffer buf2
            (kargu-chat-mode))
          (let ((live (kargu-chat-list-buffers)))
            (should (member buf1 live))
            (should (member buf2 live)))
          ;; Switching respects current mode
          (with-current-buffer buf1
            (should (derived-mode-p 'kargu-chat-mode))))
      (kill-buffer buf1)
      (kill-buffer buf2))))

(ert-deftest kargu-chat-mode-selector-footer-test ()
  "Test mode selector in footer, company integration, header line, and buffer cleanup."
  (let ((chat-buf (get-buffer-create "*kargu-chat-mode-test*")))
    (unwind-protect
        (with-current-buffer chat-buf
          (kargu-chat-mode)
          (kargu-chat--ensure-idle-prompt)
          ;; Initially ASK
          (kargu-set-mode 'ask)
          (should (string-match-p "mode: \\[ASK\\]" (buffer-string)))
          (should (string-match-p "kargu · \\[ASK\\]" (kargu-chat--header-string)))
          ;; Change to PLAN: footer and header must update!
          (kargu-set-mode 'plan)
          (should (eq (kargu-state-mode) 'plan))
          (should (string-match-p "mode: \\[PLAN\\]" (buffer-string)))
          (should (string-match-p "kargu · \\[PLAN\\]" (kargu-chat--header-string)))
          ;; Check that top obsolete mode buttons are absent
          (should-not (string-match-p "Mode: \\[ask\\]" (buffer-string)))
          ;; Test company selector fallback in batch mode
          (cl-letf (((symbol-function 'kargu--completing-read-with-company)
                     (lambda (_p _c _d _a) "agent")))
            (kargu-chat-select-mode-company)
            (should (eq (kargu-state-mode) 'agent))
            (should (string-match-p "mode: \\[AGENT\\]" (buffer-string)))
            (should (string-match-p "kargu · \\[AGENT\\]" (kargu-chat--header-string)))))
      (kill-buffer chat-buf))))

(ert-deftest kargu-chat-selection-guard-while-running-test ()
  "Test model and provider completion guard while loop is running."
  (cl-letf (((symbol-function 'kargu-loop-running-p) (lambda () t)))
    (should-error (kargu-chat-select-model-company) :type 'user-error)
    (should-error (kargu-chat-select-provider-company) :type 'user-error)))

(ert-deftest kargu-chat-company-at-mention-test ()
  "Test that `@' mention completion works at prompt and restores cleanly."
  (kargu-test-with-git-repo '(("tests/test-git.el" . "x") ("tests/test-fs.el" . "y") ("main.el" . "z"))
                            (let ((chat-buf (get-buffer-create "*kargu-chat-complete-test*")))
                              (unwind-protect
                                  (with-current-buffer chat-buf
                                    (kargu-chat-mode)
                                    (kargu-chat--ensure-idle-prompt)
                                    (goto-char (point-max))
                                    ;; Initial prompt state must have kargu-chat-company
                                    (should (equal company-backends '(kargu-chat-company)))
                                    (should (= company-minimum-prefix-length 1))
                                    ;; Type `@'
                                    (insert "@")
                                    (should (equal (kargu-chat--at-prefix) "@"))
                                    (let ((cands (kargu-chat-company 'candidates "@")))
                                      (should (listp cands))
                                      (should (> (length cands) 0)))
                                    ;; Rogue company-backend clearing
                                    (let ((rogue (lambda (&rest _) nil)))
                                      (setq company-backend rogue)
                                      (kargu-chat--maybe-company)
                                      (should-not (eq company-backend rogue))
                                      (should (equal company-backends '(kargu-chat-company))))
                                    (setq company-backend nil)
                                    ;; Typing `@' calls maybe-company which triggers company-manual-begin
                                    (let ((triggered nil))
                                      (cl-letf (((symbol-function 'company-manual-begin) (lambda () (setq triggered t))))
                                        (kargu-chat--maybe-company)
                                        (should triggered)))
                                    ;; Test symbol completion candidates with LSP symbols
                                    (cl-letf (((symbol-function 'kargu-lsp-all-symbols)
                                               (lambda (&optional _q _r)
                                                 '(("/path/to/main.go" 42 "CalcTotal" "Function")
                                                   ("/path/to/user.go" 10 "UserStruct" "Struct")))))
                                      ;; Query without ::
                                      (let ((sym-cands (kargu-chat--symbol-candidates "Calc")))
                                        (should (listp sym-cands))
                                        (should (> (length sym-cands) 0))
                                        (should (cl-some (lambda (c) (string-match-p "CalcTotal" c)) sym-cands)))
                                      ;; Query with :: delimiter
                                      (let ((cands (kargu-chat-company 'candidates "@main.go::Calc")))
                                        (should (listp cands))
                                        (should (> (length cands) 0))
                                        (should (cl-some (lambda (c) (string-match-p "CalcTotal" c)) cands))))
                                    ;; Ensure company-backends invariant holds
                                    (should (equal company-backends '(kargu-chat-company)))
                                    (should-not company-backend)
                                    (should (= company-minimum-prefix-length 1)))
                                (kill-buffer chat-buf)))))
(ert-deftest kargu-company-at-symbol-typing-cycle-test ()
  "Test that continuous typing after `@' preserves company-backend and handles kind/require-match."
  (kargu-test-with-git-repo '(("tests/test-git.el" . "x") ("tests/test-fs.el" . "y") ("main.el" . "z"))
                            (let ((chat-buf (get-buffer-create "*kargu-chat-typing-test*")))
                              (unwind-protect
                                  (with-current-buffer chat-buf
                                    (kargu-chat-mode)
                                    (kargu-chat--ensure-idle-prompt)
                                    (goto-char (point-max))
                                    ;; 1. Verify kargu-chat-company protocol commands
                                    (let ((file-cands (kargu-chat-company 'candidates "@tests/test-git.el")))
                                      (should (consp file-cands))
                                      (let ((cand (car file-cands)))
                                        (should (equal (get-text-property 0 'company-backend cand) 'kargu-chat-company))
                                        (should (equal (kargu-chat-company 'kind cand) 'file))
                                        (should (stringp (kargu-chat-company 'meta cand)))))
                                    (should (eq (kargu-chat-company 'require-match) 'never))

                                    ;; 2. Simulate typing `@' followed by incremental characters
                                    (insert "@")
                                    (kargu-chat--maybe-company)
                                    (should (equal company-backend 'kargu-chat-company))
                                    (should (consp company-candidates))

                                    ;; 3. Insert character while completion is active
                                    (insert "s")
                                    (kargu-chat--maybe-company)
                                    ;; company-backend must NOT be reset to nil
                                    (should (equal company-backend 'kargu-chat-company))

                                    ;; 4. Verify kind call on candidate works cleanly (no void: nil error)
                                    (let ((kind (company-call-backend 'kind (car company-candidates))))
                                      (should (memq kind '(file function variable struct method))))

                                    ;; 5. Even if company-backend were forced to nil, candidate property prevents crash
                                    (setq company-backend nil)
                                    (let ((cand (car (kargu-chat-company 'candidates "@tests"))))
                                      (should (equal (company-call-backend 'kind cand) 'file))))
                                (kill-buffer chat-buf)))))
(ert-deftest kargu-chat-request-uses-the-buffer-model-test ()
  "A request from a chat carries that chat's model, and the other chat keeps its own."
  (let ((buf1 (get-buffer-create "*kargu-chat-sel-1*"))
        (buf2 (get-buffer-create "*kargu-chat-sel-2*"))
        (kargu--session-provider "openrouter")
        (kargu--session-model "model-shared"))
    (unwind-protect
        (progn
          (with-current-buffer buf1
            (kargu-chat-mode)
            (kargu-chat-note-selection))
          (with-current-buffer buf2
            (kargu-chat-mode)
            (kargu-chat-note-selection))
          (with-current-buffer buf1
            (kargu-set-model "model-one"))
          (with-current-buffer buf1
            (should (equal (kargu--model) "model-one"))
            (should (equal (kargu-aget (kargu--build-payload) "model") "model-one"))
            (should (equal kargu-chat--session-model "model-one")))
          (with-current-buffer buf2
            (should (equal (kargu--model) "model-shared"))
            (should (equal kargu-chat--session-model "model-shared"))
            (should (equal (kargu-aget (kargu--build-payload) "model") "model-shared"))))
      (when (buffer-live-p buf1) (kill-buffer buf1))
      (when (buffer-live-p buf2) (kill-buffer buf2)))))

(ert-deftest kargu-chat-tool-heading-shows-path-test ()
  "Tool lines name the target, and a normal result is ok rather than a char count."
  (require 'kargu/chat/render)
  (should (equal (kargu-chat--tool-heading
                  "read_file" '(("path" . "kargu/loop/machine.el")))
                 "  → read_file kargu/loop/machine.el"))
  (should (equal (kargu-chat--tool-heading
                  "bash" '(("command" . "git status")))
                 "  → bash git status"))
  (should (equal (kargu-chat--tool-heading
                  "workspace_grep" '(("pattern" . "classify")
                                     ("path" . "kargu/loop")))
                 "  → workspace_grep classify kargu/loop"))
  (should (equal (kargu-chat--tool-heading
                  "webfetch" '(("url" . "https://example.com")))
                 "  → webfetch https://example.com"))
  (should (equal (kargu-chat--result-summary "file contents") "ok"))
  (should (string-prefix-p "ERROR:" (kargu-chat--result-summary "ERROR: missing")))
  (should-not (string-match-p "chars" (kargu-chat--result-summary "file contents"))))

(ert-deftest kargu-menu-without-eglot-remains-usable-test ()
  "The menu opens without referencing the removed Eglot admission gate."
  (let (opened)
    (cl-letf (((symbol-function 'kargu-eglot-connected-p) (lambda () nil))
              ((symbol-function 'transient-setup) (lambda (prefix &rest _) (setq opened prefix))))
      (kargu-menu)
      (should (eq opened 'kargu-menu))
      (should (kargu-menu--lsp-unavailable-p)))))

(ert-deftest kargu-chat-output-preserves-draft-cursors-test ()
  "Streaming output preserves separate input offsets in every window."
  (save-window-excursion
    (with-temp-buffer
      (kargu-chat-mode)
      (kargu-chat--ensure-idle-prompt)
      (insert "first line\nsecond line")
      (switch-to-buffer (current-buffer))
      (let* ((first (selected-window))
             (second (split-window first nil 'below))
             (start (marker-position kargu-chat--prompt-marker)))
        (goto-char (+ start 3))
        (set-mark (+ start 8))
        (set-window-point second (+ start 15))
        (dotimes (_ 3) (kargu-chat-insert "output\n"))
        (setq start (marker-position kargu-chat--prompt-marker))
        (should (= (point) (+ start 3)))
        (should (= (mark) (+ start 8)))
        (should (= (window-point first) (+ start 3)))
        (should (= (window-point second) (+ start 15)))
        (should (equal (kargu-chat--input-text) "first line\nsecond line"))))))

(ert-deftest kargu-chat-footer-preserves-draft-cursors-test ()
  "Footer replacement keeps draft properties, mark and window offsets."
  (save-window-excursion
    (with-temp-buffer
      (kargu-chat-mode)
      (kargu-chat--ensure-idle-prompt)
      (insert (propertize "first line\nsecond line" 'kargu-test t))
      (switch-to-buffer (current-buffer))
      (let ((second (split-window (selected-window) nil 'below)))
        (dolist (offset '(0 3 15 22))
          (goto-char (+ kargu-chat--prompt-marker offset))
          (set-mark (+ kargu-chat--prompt-marker 8))
          (set-window-point second (+ kargu-chat--prompt-marker 12))
          (cl-letf (((symbol-function 'kargu-chat--footer-string)
                     (lambda () (propertize "a changed footer\n" 'field 'prompt))))
            (kargu-chat-refresh-footer))
          (should (= (point) (+ kargu-chat--prompt-marker offset)))
          (should (= (mark) (+ kargu-chat--prompt-marker 8)))
          (should (= (window-point second) (+ kargu-chat--prompt-marker 12)))
          (should (get-text-property kargu-chat--prompt-marker 'kargu-test))
          (should (kargu-chat--prompt-live-p)))))))

(ert-deftest kargu-chat-beginning-of-line-respects-input-lines-test ()
  "C-a visits each input line start without entering the prompt prefix."
  (with-temp-buffer
    (kargu-chat-mode)
    (kargu-chat--ensure-idle-prompt)
    (insert "first\nsecond\nthird")
    (dolist (offset '(17 11 5))
      (goto-char (+ kargu-chat--prompt-marker offset))
      (let ((expected (max (marker-position kargu-chat--prompt-marker)
                           (line-beginning-position))))
        (kargu-chat-beginning-of-line)
        (should (= (point) expected))))))

(ert-deftest kargu-chat-startup-rejection-restores-input-test ()
  "A late startup refusal restores the complete prompt without orphan turns."
  (with-temp-buffer
    (kargu-chat-mode)
    (setq-local kargu-chat--session-provider "p"
                kargu-chat--session-model "m")
    (kargu-chat--ensure-idle-prompt)
    (insert (propertize "  keep my draft  \n" 'kargu-test t))
    (goto-char (+ kargu-chat--prompt-marker 4))
    (set-mark (+ kargu-chat--prompt-marker 8))
    (let ((before (buffer-string))
          (saved-point (point))
          (saved-mark (mark))
          (kargu-chat-input-history nil)
          (kargu--loop-run nil))
      (cl-letf (((symbol-function 'kargu-deps-missing) (lambda (&rest _) nil))
                ((symbol-function 'kargu-chat--expand-prompt) #'identity)
                ((symbol-function 'kargu-loop-send)
                 (lambda (&rest _) (user-error "late refusal"))))
        (should-error (kargu-chat--send-input) :type 'user-error))
      (should (equal-including-properties (buffer-string) before))
      (should (= (point) saved-point))
      (should (= (mark) saved-mark))
      (should (kargu-chat--prompt-live-p))
      (should-not kargu-chat-input-history)
      (should-not (kargu-loop-running-p)))))

(ert-deftest kargu-chat-expansion-failure-keeps-input-test ()
  "Attachment expansion failure happens before draft or transcript mutation."
  (with-temp-buffer
    (kargu-chat-mode)
    (setq-local kargu-chat--session-provider "p"
                kargu-chat--session-model "m")
    (kargu-chat--ensure-idle-prompt)
    (insert "@file.md")
    (let ((before (buffer-string)))
      (cl-letf (((symbol-function 'kargu-deps-missing) (lambda (&rest _) nil))
                ((symbol-function 'kargu-chat--expand-prompt)
                 (lambda (_) (error "unreadable attachment"))))
        (should-error (kargu-chat--send-input)))
      (should (equal-including-properties (buffer-string) before))
      (should (kargu-chat--prompt-live-p)))))

(ert-deftest kargu-chat-programmatic-prompt-preserves-draft-test ()
  "A plan-style prompt keeps an unrelated draft across every terminal status."
  (dolist (synchronous '(nil t))
    (dolist (status '(:done :error :stopped))
      (with-temp-buffer
	(kargu-chat-mode)
	(setq-local kargu-chat--session-provider "p"
                    kargu-chat--session-model "m")
	(kargu-chat--ensure-idle-prompt)
	(insert (propertize "unsent notes\n  " 'kargu-test t))
	(goto-char (+ kargu-chat--prompt-marker 4))
	(set-mark (+ kargu-chat--prompt-marker 8))
	(let ((chat (current-buffer)) callback sent)
          (cl-letf (((symbol-function 'kargu-deps-missing) (lambda (&rest _) nil))
                    ((symbol-function 'kargu-chat-show) (lambda () chat))
                    ((symbol-function 'kargu-chat--buffer) (lambda (&rest _) chat))
                    ((symbol-function 'kargu-chat--expand-prompt) #'identity)
                    ((symbol-function 'kargu-loop-send)
                     (lambda (prompt _delta finish)
                       (setq sent prompt callback finish)
                       (when synchronous
			 (funcall finish (list :status status :text "result"
                                               :error "failure"))))))
            (kargu-chat-prompt "Apply the approved plan")
            (should (equal sent "Apply the approved plan"))
            (unless synchronous
              (should-not (kargu-chat--prompt-live-p))
              (with-temp-buffer
		(funcall callback (list :status status :text "result"
					:error "failure"))))
            (should (kargu-chat--prompt-live-p))
            (should (equal (buffer-substring-no-properties
                            kargu-chat--prompt-marker (point-max))
                           "unsent notes\n  "))
            (should (get-text-property kargu-chat--prompt-marker 'kargu-test))
            (should (= (point) (+ kargu-chat--prompt-marker 4)))
            (should (= (mark) (+ kargu-chat--prompt-marker 8)))))))))

(ert-deftest kargu-chat-completion-never-adds-unrelated-buffer-roots-test ()
  "An unrelated file buffer is neither scanned nor offered as a mention."
  (kargu-test-with-git-repo '(("local.el" . "local"))
    (let ((foreign (generate-new-buffer " *kargu-foreign-completion*")))
      (unwind-protect
          (progn
            (with-current-buffer foreign
              (setq buffer-file-name "/tmp/other-project/secret.el"))
            (cl-letf (((symbol-function 'project-current)
                       (lambda (&rest _) (error "Must not scan other buffer projects"))))
              (should (equal (kargu-chat--completion-roots) (list repo))))
            (cl-letf (((symbol-function 'kargu-chat--project-absolute-files)
                       (lambda (root)
                         (should (equal root repo))
                         (list (expand-file-name "local.el" root)))))
              (let ((files (kargu-chat--collect-files (kargu-chat--completion-roots))))
                (should (member "local.el" files))
                (should-not (member "secret.el" files)))))
        (kill-buffer foreign)))))

(ert-deftest kargu-chat-retries-replace-only-the-failed-request-output-test ()
  "HTTP and loop retries keep prior logs and the draft but discard partial deltas."
  (with-temp-buffer
    (kargu-chat-mode)
    (kargu-chat--ensure-idle-prompt)
    (insert "unsent draft")
    (let* ((run (list :state 'request :chat-buffer (current-buffer)
                      :on-delta #'kargu-chat--on-delta))
           (kargu--loop-run run) (kargu--generation 100) delta)
      (kargu-chat-insert "earlier tool [ok]\n")
      (cl-letf (((symbol-function 'kargu-api-send)
                 (lambda (_prompt _callback on-delta) (setq delta on-delta))))
        (kargu-loop--send-model run "prompt"))
      (funcall delta '(("choices" . [(("delta" . (("content" . "discarded<thi"))))])))
      (let ((before (buffer-string)))
        (kargu-loop--on-api-retry 100 #'ignore)
        (should (equal-including-properties (buffer-string) before)))
      (cl-letf (((symbol-function 'kargu--api-post)
                 (lambda (&rest _)
                   (funcall delta '(("choices" . [(("delta" . (("content" . "replacement"))))]))))))
        (kargu-api--retry-post 100 :on-delta delta))
      (should (string-search "earlier tool [ok]" (buffer-string)))
      (should (string-search "replacement" (buffer-string)))
      (should-not (string-search "discarded" (buffer-string)))
      (should (equal kargu-chat--thought-pending ""))
      (cl-letf (((symbol-function 'kargu--loop-request) #'ignore))
        (kargu-loop--retry-model run))
      (should-not (string-search "replacement" (buffer-string)))
      (should (equal (buffer-substring-no-properties
                      kargu-chat--prompt-marker (point-max)) "unsent draft"))
      (let ((before (buffer-string)))
        (setq kargu--loop-run (list :state 'request))
        (kargu-chat--model-stream-event run 'retry)
        (should (equal-including-properties before (buffer-string)))))))

(ert-deftest kargu-chat-loop-observers-never-edit-source-buffers-test ()
  "Library loop calls outside chat mode never write UI text into source code."
  (with-temp-buffer
    (emacs-lisp-mode)
    (insert ";; source buffer must remain untouched\n")
    (let* ((run (list :state 'tools :chat-buffer (current-buffer)))
           (kargu--loop-run run) (before (buffer-string)))
      (cl-letf (((symbol-function 'kargu-api-send) #'ignore)
                ((symbol-function 'kargu-execute-tool)
                 (lambda (_name _arguments callback) (funcall callback "ok")))
                ((symbol-function 'kargu--loop-after-tool) #'ignore))
        (kargu-loop--send-model run "prompt")
        (kargu--loop-execute-call run :id "one" :name "read_file")
        (should (equal-including-properties before (buffer-string)))))))

(ert-deftest kargu-chat-unowned-tool-calls-do-not-pollute-transcript-test ()
  "Calling the tool API outside a loop leaves an existing chat untouched."
  (with-temp-buffer
    (kargu-chat-mode)
    (kargu-chat--ensure-idle-prompt)
    (let ((before (buffer-string)) (kargu--loop-run nil) result)
      (kargu-execute-tool "nonexistent-tool" nil (lambda (text) (setq result text)))
      (should (stringp result))
      (should (equal-including-properties before (buffer-string))))))

(ert-deftest kargu-chat-owned-tool-events-retain-each-tool-log-test ()
  "Loop-owned tool activity retains both logs when preambles are hidden."
  (with-temp-buffer
    (kargu-chat-mode)
    (kargu-chat--ensure-idle-prompt)
    (let* ((run (list :state 'tools :chat-buffer (current-buffer)))
           (kargu--loop-run run)
           (kargu-chat-drop-preamble t))
      (kargu-chat--mark-answer-start)
      (kargu-chat--on-delta "preface to hide")
      (cl-letf (((symbol-function 'kargu-execute-tool)
                 (lambda (_name _args callback) (funcall callback "ok")))
                ((symbol-function 'kargu--loop-after-tool) #'ignore))
        (dolist (file '("first.el" "second.el"))
          (kargu--loop-execute-call
           run :id file :name "read_file" :args (list (cons "file_path" file)))))
      (should (string-search "first.el" (buffer-string)))
      (should (string-search "second.el" (buffer-string)))
      (should-not (string-search "preface to hide" (buffer-string))))))

(ert-deftest kargu-chat-stale-tool-results-and-failing-observers-test ()
  "A stale result cannot touch a newer run; observers cannot break delivery."
  (with-temp-buffer
    (kargu-chat-mode)
    (kargu-chat--ensure-idle-prompt)
    (let* ((run (list :state 'tools :chat-buffer (current-buffer)))
           (kargu--loop-run run)
           (kargu-loop-tool-start-hook
            (cons (lambda (&rest _) (error "bad observer"))
                  kargu-loop-tool-start-hook))
           (kargu-loop-tool-finish-hook
            (cons (lambda (&rest _) (error "bad observer"))
                  kargu-loop-tool-finish-hook))
           callback (deliveries 0))
      (cl-letf (((symbol-function 'kargu-execute-tool)
                 (lambda (_name _args cb) (setq callback cb)))
                ((symbol-function 'kargu--loop-after-tool)
                 (lambda (&rest _) (cl-incf deliveries))))
        (kargu--loop-execute-call run :id "one" :name "read_file")
        (funcall callback "ok")
        (funcall callback "duplicate")
        (should (= deliveries 1))
        (kargu--loop-execute-call run :id "two" :name "read_file")
        (setq kargu--loop-run (list :state 'tools :chat-buffer (current-buffer)))
        (let ((before (buffer-string)))
          (funcall callback "late")
          (kargu-chat--finish-tool-activity run "late observer")
          (should (equal-including-properties before (buffer-string))))
        (should (= deliveries 1))))))

(provide 'tests/test-chat)
;;; test-chat.el ends here
