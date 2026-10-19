;;; selection.el --- Captured debugger inspection selection -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Reading a reply must not consult a selection made after the request.
;; The thread object receives Dape's stack reply; the selected frame ID is
;; immutable and resolved against that thread's refreshed stack only.

;;; Code:

(require 'cl-lib)
(require 'kargu/json)
(require 'kargu/tools/dape/events)

(declare-function dape--current-thread "dape" (conn))
(declare-function dape--stopped-threads "dape" (conn))
(declare-function dape--current-stack-frame "dape" (conn))

(cl-defstruct (kargu-dape-selection (:constructor kargu-dape--make-selection))
  "Captured CONNECTION, THREAD and immutable selection/state identities."
  connection thread thread-id frame-id generation)

(defun kargu-dape-capture-selection (connection)
  "Capture CONNECTION's current thread and frame identity before any request."
  (let ((thread (or (dape--current-thread connection)
                    (car (dape--stopped-threads connection))))
        (frame (dape--current-stack-frame connection)))
    (kargu-dape--make-selection :connection connection :thread thread
                               :thread-id (plist-get thread :id) :frame-id (plist-get frame :id)
                               :generation (kargu-dape-event-generation connection))))

(defun kargu-dape-selection-frame (selection)
  "Resolve SELECTION's frame only within its captured thread's refreshed stack.
An initially unspecified frame selects the first returned frame.  A missing
explicit frame returns nil rather than adopting another thread or frame."
  (let ((frames (kargu-seq-to-list (plist-get (kargu-dape-selection-thread selection) :stackFrames)))
        (id (kargu-dape-selection-frame-id selection)))
    (if id (seq-find (lambda (frame) (equal id (plist-get frame :id))) frames)
      (car frames))))

(defun kargu-dape-selection-current-p (selection)
  "Return non-nil when SELECTION is still the adapter's UI selection.
Use this before a delayed navigation command changes that selection."
  (let ((current (kargu-dape-capture-selection (kargu-dape-selection-connection selection))))
    (and (= (kargu-dape-selection-generation selection) (kargu-dape-selection-generation current))
         (equal (kargu-dape-selection-thread-id selection) (kargu-dape-selection-thread-id current))
         (equal (kargu-dape-selection-frame-id selection) (kargu-dape-selection-frame-id current)))))

(provide 'kargu/tools/dape/selection)
;;; selection.el ends here
