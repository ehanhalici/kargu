;;; test-dape-selection.el --- Captured thread/frame context tests -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; UI selection changes between delayed stack, scope and variable replies
;; must not redirect reads or a pending navigation command.

;;; Code:

(require 'ert)
(require 'kargu)
(require 'tests/test-helpers)

(defmacro kargu-dape-test--with-selection (&rest body)
  "Run BODY with two threads, controlled replies and a mutable UI selection."
  (declare (indent 0))
  `(with-temp-buffer
     (let* ((frame-a (list :id 11 :name "owner-a" :line 1))
            (frame-b (list :id 12 :name "owner-b" :line 2))
            (frame-c (list :id 21 :name "foreign-frame" :line 3))
            (thread-a (list :id 1 :status 'stopped :stackFrames (vector frame-a frame-b)))
            (thread-b (list :id 2 :status 'stopped :stackFrames (vector frame-c)))
            (selected-thread thread-a) (selected-frame frame-a)
            (kargu--loop-run (list :state 'tools)) (kargu-async--pending nil)
            (requests nil) (results nil) (moves nil)
            (stack-reply nil) (scope-reply nil) (variable-reply nil))
       (ignore thread-b selected-thread selected-frame requests results moves stack-reply scope-reply variable-reply)
       (unwind-protect
           (cl-letf (((symbol-function 'kargu-dape--connection) (lambda () 'local))
                     ((symbol-function 'kargu-dape--raw-connection) (lambda () 'local))
                     ((symbol-function 'kargu-dape-project-connections) (lambda (&optional _) '(local)))
                     ((symbol-function 'dape--current-thread) (lambda (_) selected-thread))
                     ((symbol-function 'dape--threads) (lambda (_) (list thread-a thread-b)))
                     ((symbol-function 'dape--thread-id) (lambda (_) (plist-get selected-thread :id)))
                     ((symbol-function 'dape--stack-id) (lambda (_) (plist-get selected-frame :id)))
                     ((symbol-function 'dape--current-stack-frame) (lambda (_) selected-frame))
                     ((symbol-function 'dape--stopped-threads) (lambda (_) (list thread-a thread-b)))
                     ((symbol-function 'dape--stack-trace)
                      (lambda (_conn thread _limit callback)
                        (push (list :stack (plist-get thread :id)) requests)
                        (let ((source (if (equal (plist-get thread :id) 1) thread-a thread-b)))
                          (setq stack-reply
                                (lambda ()
                                  (setf (plist-get thread :stackFrames)
                                        (copy-tree (plist-get source :stackFrames) t))
                                  (funcall callback))))))
                     ((symbol-function 'dape--scopes)
                      (lambda (_conn frame callback)
                        (let ((id (plist-get frame :id)))
                          (push (list :scopes id) requests)
                          (plist-put frame :scopes (list (list :name "Locals" :variablesReference id)))
                          (setq scope-reply callback))))
                     ((symbol-function 'dape--variables)
                      (lambda (_conn scope callback)
                        (let ((id (plist-get scope :variablesReference)))
                          (push (list :variables id) requests)
                          (plist-put scope :variables (list (list :name "captured" :value (number-to-string id))))
                          (setq variable-reply callback))))
                     ((symbol-function 'dape-select-stack)
                      (lambda (_conn id)
                        (push id moves)
                        (setq selected-frame
                              (seq-find (lambda (frame) (equal id (plist-get frame :id)))
                                        (append (plist-get selected-thread :stackFrames) nil))))))
             ,@body)
         (kargu-async-cancel-owner kargu--loop-run)))))

(ert-deftest kargu-dape-selection-context-keeps-original-thread-and-frame-test ()
  "Selection changes at every callback boundary cannot mix thread/frame data."
  (kargu-dape-test--with-selection
    (kargu-dape-get-context (lambda (text) (push text results)))
    (setq selected-thread thread-b selected-frame frame-c)
    (funcall stack-reply)
    (setq selected-thread thread-a selected-frame frame-b)
    (funcall scope-reply)
    (setq selected-thread thread-b selected-frame frame-c)
    (funcall variable-reply)
    (funcall variable-reply)
    (should (equal (reverse requests) '((:stack 1) (:scopes 11) (:variables 11))))
    (should (= (length results) 1))
    (should (string-search "thread #1" (car results)))
    (should (string-search "Variables in frame \"owner-a\"" (car results)))
    (should (string-search "captured = 11" (car results)))
    (should-not (string-search "foreign-frame" (car results)))
    (should-not kargu-async--pending)))

(ert-deftest kargu-dape-selection-resolves-id-in-refreshed-stack-test ()
  "A refreshed frame object is resolved by captured ID, not stale object identity."
  (kargu-dape-test--with-selection
    (kargu-dape-get-context (lambda (text) (push text results)))
    (plist-put thread-a :stackFrames (vector (list :id 11 :name "refreshed-owner")))
    (setq selected-frame frame-b)
    (funcall stack-reply)
    (funcall scope-reply)
    (funcall variable-reply)
    (should (string-search "Variables in frame \"refreshed-owner\"" (car results)))
    (should (equal (reverse requests) '((:stack 1) (:scopes 11) (:variables 11))))))

(ert-deftest kargu-dape-selection-unspecified-frame-uses-captured-thread-test ()
  "An initially unspecified frame uses its own stack, not a later UI selection."
  (kargu-dape-test--with-selection
    (setq selected-frame nil)
    (kargu-dape-get-context (lambda (text) (push text results)))
    (setq selected-thread thread-b selected-frame frame-c)
    (funcall stack-reply)
    (funcall scope-reply)
    (funcall variable-reply)
    (should (string-search "Variables in frame \"owner-a\"" (car results)))
    (should (equal (reverse requests) '((:stack 1) (:scopes 11) (:variables 11))))))

(ert-deftest kargu-dape-selection-missing-captured-frame-is-unavailable-test ()
  "An absent captured frame cannot fall back to another available frame."
  (kargu-dape-test--with-selection
    (kargu-dape-get-context (lambda (text) (push text results)))
    (plist-put thread-a :stackFrames (vector frame-b))
    (setq selected-frame frame-b)
    (funcall stack-reply)
    (funcall stack-reply)
    (should (equal requests '((:stack 1))))
    (should (= (length results) 1))
    (should (string-search "Requested debug frame is absent" (car results)))
    (should-not kargu-async--pending)))

(ert-deftest kargu-dape-selection-paused-report-keeps-captured-location-test ()
  "A paused report's location and variables describe the same captured frame."
  (kargu-dape-test--with-selection
    (kargu-dape--format-stopped-report "continue" (lambda (text) (push text results)) 'local)
    (setq selected-thread thread-b selected-frame frame-c)
    (funcall stack-reply)
    (funcall scope-reply)
    (funcall variable-reply)
    (should (string-search "in `owner-a`" (car results)))
    (should (string-search "Variables in frame \"owner-a\"" (car results)))
    (should-not (string-search "foreign-frame" (car results)))))

(ert-deftest kargu-dape-selection-navigation-rejects-intervening-selection-test ()
  "Pending navigation cannot overwrite a newer thread/frame selection."
  (dolist (change '(frame thread))
    (kargu-dape-test--with-selection
      (kargu-dape-up 1 (lambda (text) (push text results)))
      (pcase change
        ('frame (setq selected-frame frame-b))
        ('thread (setq selected-thread thread-b)))
      (funcall stack-reply)
      (funcall stack-reply)
      (should-not moves)
      (should (= (length results) 1))
      (should (string-search "Debug selection changed" (car results)))
      (should-not kargu-async--pending))))

(ert-deftest kargu-dape-selection-navigation-allows-own-move-test ()
  "An intentional navigation move can still collect its newly selected frame."
  (dolist (direction '(up down))
    (kargu-dape-test--with-selection
      (if (eq direction 'up)
          (kargu-dape-up 1 (lambda (text) (push text results)))
        (setq selected-frame frame-b)
        (kargu-dape-down 1 (lambda (text) (push text results))))
      (funcall stack-reply)
      (should (equal moves (if (eq direction 'up) '(12) '(11))))
      (funcall stack-reply)
      (funcall scope-reply)
      (funcall variable-reply)
      (should (= (length results) 1))
      (should (string-search (if (eq direction 'up) "STACK UP" "STACK DOWN") (car results)))
      (should (string-search (if (eq direction 'up) "Variables in frame \"owner-b\""
                               "Variables in frame \"owner-a\"") (car results)))
      (should-not kargu-async--pending))))

(ert-deftest kargu-dape-selection-mismatched-adapter-is-rejected-test ()
  "A caller cannot pair an admitted connection with another adapter's selection."
  (kargu-dape-test--with-selection
    (let ((selection (kargu-dape-capture-selection 'foreign)))
      (kargu-dape-get-context (lambda (text) (push text results)) 'local selection)
      (should-not requests)
      (should (string-search "belongs to another adapter" (car results)))
      (should-not kargu-async--pending))))

(ert-deftest kargu-dape-selection-navigation-rejects-missing-anchor-test ()
  "Navigation cannot silently rebase onto a refreshed stack's first frame."
  (kargu-dape-test--with-selection
    (kargu-dape-up 1 (lambda (text) (push text results)))
    (plist-put thread-a :stackFrames (vector frame-b frame-c))
    (funcall stack-reply)
    (should-not moves)
    (should (string-search "Requested debug frame is absent" (car results)))
    (should-not kargu-async--pending)))

(ert-deftest kargu-dape-selection-context-preserves-editor-state-test ()
  "Captured reads preserve caller narrowing, point and match data."
  (kargu-dape-test--with-selection
    (insert "caller state\n")
    (narrow-to-region 2 9)
    (goto-char 5)
    (string-match "state" "caller state")
    (let ((matches (match-data t)))
      (kargu-dape-get-context (lambda (text) (push text results)))
      (funcall stack-reply)
      (funcall scope-reply)
      (funcall variable-reply)
      (should (equal matches (match-data t))))
    (should (= (point) 5))
    (should (= (point-min) 2))
    (should (= (point-max) 9))
    (should (= (length results) 1))))

(ert-deftest kargu-dape-selection-stack-highlight-keeps-original-frame-test ()
  "A delayed stack list cannot label a newer UI selection as the captured one."
  (kargu-dape-test--with-selection
    (kargu-dape-stack 10 (lambda (text) (push text results)))
    (setq selected-frame frame-b)
    (funcall stack-reply)
    (let ((lines (split-string (car results) "\n")))
      (should (seq-some (lambda (line) (and (string-search "owner-a" line)
                                           (string-search "<= selected" line))) lines))
      (should-not (seq-some (lambda (line) (and (string-search "owner-b" line)
                                               (string-search "<= selected" line))) lines)))
    (should-not kargu-async--pending)))

(ert-deftest kargu-dape-selection-stack-matches-refreshed-large-id-test ()
  "Frame identity is value-based even for separately decoded large integers."
  (kargu-dape-test--with-selection
    (plist-put frame-a :id (string-to-number "100000000000000000000001"))
    (kargu-dape-stack 10 (lambda (text) (push text results)))
    (plist-put thread-a :stackFrames
               (vector (list :id (string-to-number "100000000000000000000001") :name "refreshed")))
    (funcall stack-reply)
    (should (string-search "<= selected" (car results)))
    (should-not kargu-async--pending)))

(ert-deftest kargu-dape-selection-explicit-stale-state-is-rejected-test ()
  "A selection saved before continue/stop cannot start a new context request."
  (kargu-dape-test--with-selection
    (let* ((kargu-dape--event-generations (make-hash-table :test #'eq :weakness 'key))
           (selection (kargu-dape-capture-selection 'local)))
      (kargu-dape--observe-event 'local 'continued nil)
      (kargu-dape--observe-event 'local 'stopped nil)
      (kargu-dape-get-context (lambda (text) (push text results)) 'local selection)
      (should-not requests)
      (should (string-search "selection state changed" (car results)))
      (should-not kargu-async--pending))))

(ert-deftest kargu-dape-selection-context-highlight-matches-large-id-test ()
  "Context rendering compares decoded frame IDs by value, not object identity."
  (kargu-dape-test--with-selection
    (let* ((id "100000000000000000000001")
           (frame (list :id (string-to-number id) :name "refreshed"))
           (selected (list :id (string-to-number id))))
      (should-not (eq (plist-get frame :id) (plist-get selected :id)))
      (let ((lines (kargu-dape--render-stack-frames 'local (list frame frame-b) selected)))
        (should (seq-some (lambda (line) (and (string-search "refreshed" line)
                                             (string-search "<= selected" line))) lines))
        (should-not (seq-some (lambda (line) (and (string-search "owner-b" line)
                                                 (string-search "<= selected" line))) lines))))))

(provide 'tests/test-dape-selection)
;;; test-dape-selection.el ends here
