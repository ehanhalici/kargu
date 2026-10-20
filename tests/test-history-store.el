;;; test-history-store.el --- Owned conversation regression tests -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Container ownership, queue complexity and foreign-buffer delivery must
;; agree with the native protocol wall and session persistence adapter.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'tests/test-helpers)
(require 'kargu/history)
(require 'kargu/api/client)
(require 'kargu/loop)
(require 'kargu/chat/session)

(defmacro kargu-history-test--with-owners (&rest body)
  "Run BODY with two temporary session buffers named `a' and `b'."
  (declare (indent 0))
  `(let ((a (generate-new-buffer " *kargu-history-a*"))
         (b (generate-new-buffer " *kargu-history-b*"))
         (kargu-session-auto-save nil))
     (unwind-protect (progn ,@body)
       (when (buffer-live-p a) (kill-buffer a))
       (when (buffer-live-p b) (kill-buffer b)))))

(ert-deftest kargu-history-store-copies-draft-containers-test ()
  "Input and snapshot containers cannot mutate the owned queue."
  (let* ((message (copy-tree '(("role" . "user") ("content" . [(("text" . "hello"))])) t))
         (history (kargu-history-create :messages (list message)))
         (snapshot (kargu-history-snapshot history)))
    (setcdr (assoc "text" (aref (kargu-aget message "content") 0)) "input changed")
    (setcdr (assoc "role" (car snapshot)) "snapshot changed")
    (should (equal (kargu-aget (car (kargu-history-messages history)) "role") "user"))
    (should (equal (kargu-aget (aref (kargu-aget
                                    (car (kargu-history-messages history)) "content") 0)
                             "text") "hello"))
    (should-error (kargu-history-replace '(broken . chain) history))
    (should-error (kargu-history-set-overlay 12 history))
    (should (= (length (kargu-history-messages history)) 1))))

(ert-deftest kargu-history-store-append-reuses-only-owned-links-test ()
  "Repeated appends keep the head and detach previously exported snapshots."
  (let* ((history (kargu-history-create :messages '((("role" . "user") ("content" . "first")))))
         (head (kargu-history-messages history))
         (snapshot (kargu-history-snapshot history)))
    (dotimes (i 1000)
      (kargu-history-append (list '("role" . "user") (cons "content" (number-to-string i))) history))
    (should (eq head (kargu-history-messages history)))
    (should (= (length head) 1001))
    (should (= (length snapshot) 1))
    (should (equal (kargu-aget (kargu-history-last-message history) "content") "999"))
    (kargu--validate-history nil history)
    (should (= (length snapshot) 1))
    (kargu-history-append '(("role" . "assistant") ("content" . "answer")) history)
    (should (equal (kargu--history-last-role history) "assistant"))))

(ert-deftest kargu-history-session-counter-replacement-retains-one-history-test ()
  "Counter replacement keeps history; a new session gets a fresh queue."
  (with-temp-buffer
    (kargu-history-add "user" "retained")
    (let ((history (kargu-history-context)))
      (kargu-session-replace-usage '(:requests 8))
      (should (eq history (kargu-history-context)))
      (kargu-session-clear)
      (should-not (eq history (kargu-history-context)))
      (should-not (kargu-history-messages))
      (should (= (length (kargu-history-messages history)) 1)))))

(ert-deftest kargu-history-system-overlay-text-is-part-of-identity-test ()
  "Changing one nonempty overlay to another rebuilds only its owner's head."
  (let ((history (kargu-history-create)))
    (kargu-history-set-overlay "first system" history)
    (kargu--validate-history nil history)
    (let ((snapshot (kargu-history-snapshot history)))
      (kargu-history-set-overlay "second system" history)
      (kargu--validate-history nil history)
      (should (equal (kargu-aget (car snapshot) "content") "first system"))
      (should (equal (kargu-aget (car (kargu-history-messages history)) "content")
                     "second system")))))

(ert-deftest kargu-history-native-http-normalizes-in-captured-owner-test ()
  "A reply delivered in B uses A's history to normalize identities."
  (kargu-history-test--with-owners
    (let ((kargu--busy nil) (kargu--loop-run nil) held callback-owner snapshot)
      (with-current-buffer b
        (kargu-history-replace
         '((("role" . "assistant")
            ("tool_calls" . [(("id" . "provider-id"))]))))
        (setq snapshot (kargu-history-snapshot)))
      (cl-letf (((symbol-function 'kargu--resolve-api-key) (lambda () "test"))
                ((symbol-function 'kargu--api-base) (lambda () "https://example.invalid"))
                ((symbol-function 'plz)
                 (lambda (_method _url &rest options)
                   (setq held (plist-get options :then)) nil)))
        (with-current-buffer a
          (kargu-api-send "inspect" (lambda (_) (setq callback-owner (current-buffer)))))
        (with-current-buffer b
          (funcall held "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"tool_calls\":[{\"id\":\"provider-id\",\"function\":{\"name\":\"read_file\",\"arguments\":\"{}\"}}]}}]}")
          (should (eq callback-owner a))
          (should (equal (kargu-history-snapshot) snapshot)))
        (with-current-buffer a
          (should (equal (kargu-aget (car (kargu-seq-to-list
                                          (kargu-aget (kargu-history-last-message) "tool_calls")))
                                   "id") "provider-id")))))))

(ert-deftest kargu-history-foreign-stop-and-stale-compaction-keep-owner-test ()
  "Stop from B repairs A; obsolete compaction cannot clear B's overlay."
  (kargu-history-test--with-owners
    (let ((kargu--loop-run nil) (kargu--busy nil) run callback-owner snapshot)
      (cl-letf (((symbol-function 'kargu-state-mode) (lambda () 'ask))
                ((symbol-function 'kargu-deps-missing) (lambda (&rest _) nil))
                ((symbol-function 'kargu--resolve-api-key) (lambda () "test"))
                ((symbol-function 'kargu--api-base) (lambda () "https://example.invalid"))
                ((symbol-function 'kargu--api-post) #'ignore))
        (with-current-buffer a
          (setq run (kargu-loop-send "A's work" nil
                                    (lambda (_) (setq callback-owner (current-buffer))))))
        (with-current-buffer b
          (kargu-history-add "user" "B's work")
          (setq snapshot (kargu-history-snapshot))
          (kargu-history-set-overlay "B's overlay")
          (kargu-loop-stop)
          (should (eq callback-owner a))
          (should (equal (kargu-history-snapshot) snapshot))
          (kargu--loop-handle-compaction run nil)
          (should (equal (kargu-history-overlay) "B's overlay")))))))

(ert-deftest kargu-history-persistence-saves-each-live-owner-test ()
  "Saving A after B changed cannot persist B or freeze A's first snapshot."
  (kargu-history-test--with-owners
    (let (saved)
      (cl-letf (((symbol-function 'kargu-session-storage-write)
                 (lambda (_sid _root data) (push data saved) "saved")))
        (with-current-buffer a
          (kargu-history-add "user" "A1") (kargu-session-save a))
        (with-current-buffer b
          (kargu-history-add "user" "B1") (kargu-session-save b))
        (with-current-buffer a (kargu-history-add "assistant" "A2"))
        (with-current-buffer b (kargu-session-save a))
        (should (equal (mapcar (lambda (msg) (kargu-aget msg "content"))
                               (append (kargu-aget (car saved) "messages") nil))
                       '("A1" "A2")))
        (should (equal (kargu-aget (aref (kargu-aget (cadr saved) "messages") 0) "content")
                       "B1"))))))

(ert-deftest kargu-history-size-counts-only-new-messages-test ()
  "Stable queries encode nothing; appending encodes only the new suffix."
  (let ((history (kargu-history-create))
        (encode (symbol-function 'kargu-json-encode-record)) (encodes 0))
    (cl-letf (((symbol-function 'kargu-json-encode-record)
               (lambda (value) (cl-incf encodes) (funcall encode value))))
      (should (= (kargu-history-message-char-count history) 2))
      (should (= encodes 0))
      (dotimes (_ 100)
        (kargu-history-append '(("role" . "user") ("content" . "hi")) history)
        (kargu-history-message-char-count history)
        (kargu-history-message-char-count history))
      (should (= encodes 100))
      (kargu-history-replace '((("role" . "user") ("content" . "replacement"))) history)
      (kargu-history-message-char-count history)
      (should (= encodes 101)))))

(ert-deftest kargu-history-size-matches-json-for-structured-content-test ()
  "Incremental cost includes exact brackets, commas, escaping and blocks."
  (let ((history (kargu-history-create)))
    (dolist (message '((("role" . "user") ("content" . "Türkçe \"quote\"\nline"))
                       (("role" . "user") ("content" . [(("type" . "image_url")
                                                       ("image_url" . (("url" . "data:αβ"))))]))
                       (("role" . "assistant") ("content" . :json-null)
                        ("tool_calls" . [(("id" . "call") ("function" . (("arguments" . "{}"))))]))
                       (("role" . "tool") ("tool_call_id" . "call") ("content" . "done"))))
      (kargu-history-append message history)
      (should (= (kargu-history-message-char-count history)
                 (length (kargu-json-encode-record (vconcat (kargu-history-messages history)))))))
    (kargu-history-set-overlay "system" history)
    (kargu--validate-history t history)
    (should (= (kargu-history-message-char-count history)
               (length (kargu-json-encode-record (vconcat (kargu-history-messages history))))))
    (kargu-history-replace nil history)
    (should (= (kargu-history-message-char-count history) 2))))

(ert-deftest kargu-history-size-failed-measurement-keeps-published-cursor-test ()
  "A failed suffix scan never publishes a partial measurement."
  (let ((history (kargu-history-create))
        (encode (symbol-function 'kargu-json-encode-record)) (calls 0))
    (kargu-history-append '(("content" . "first")) history)
    (kargu-history-message-char-count history)
    (kargu-history-append '(("content" . "second")) history)
    (kargu-history-append '(("content" . "third")) history)
    (cl-letf (((symbol-function 'kargu-json-encode-record)
               (lambda (message)
                 (when (= (cl-incf calls) 2) (error "Measurement interrupted"))
                 (funcall encode message))))
      (should-error (kargu-history-message-char-count history)))
    (should (= (kargu-history-message-char-count history)
               (length (kargu-json-encode-record (vconcat (kargu-history-messages history))))))))

(ert-deftest kargu-history-size-keeps-live-schema-cost-and-owner-isolation-test ()
  "History caching does not freeze changing tool schemas or another owner."
  (kargu-history-test--with-owners
    (let ((schema-cost 12))
      (cl-letf (((symbol-function 'kargu-tool-schema-char-count) (lambda () schema-cost)))
        (with-current-buffer a
          (kargu-history-add "user" "A")
          (let ((before (kargu-history-char-count)))
            (setq schema-cost 27)
            (should (= (kargu-history-char-count) (+ before 15)))))
        (with-current-buffer b (should (= (kargu-history-char-count) 29)))
        (with-current-buffer a
          (kargu-history-apply-compaction "summary" nil)
          (should (= (kargu-history-char-count)
                     (+ schema-cost (length (kargu-json-encode-record
                                             (vconcat (kargu-history-messages))))))))))))

(provide 'tests/test-history-store)
;;; test-history-store.el ends here
