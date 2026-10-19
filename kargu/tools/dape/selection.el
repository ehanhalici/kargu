;;; selection.el --- Captured debugger inspection selection -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Reading a reply must not consult a selection made after the request.
;; Replies mutate a private working thread, never Dape's live cache.
;; The live thread identity and adapter epoch authorize every continuation.

;;; Code:

(require 'cl-lib)
(require 'kargu/json)
(require 'kargu/tools/dape/events)

(declare-function dape--thread-id "dape" (conn))
(declare-function dape--stack-id "dape" (conn))
(declare-function dape--threads "dape" (conn))

(cl-defstruct (kargu-dape-selection (:constructor kargu-dape--make-selection))
  "Captured CONNECTION, THREAD and immutable selection/state identities."
  connection thread live-thread thread-id frame-id generation prepared)

(defun kargu-dape-inspection-thread (connection)
  "Return CONNECTION's selected live paused thread, or nil.
Only an absent selection may default to the first paused thread."
  (let* ((threads (kargu-seq-to-list (dape--threads connection)))
         (id (dape--thread-id connection))
         (thread (if id
                     (seq-find (lambda (item) (equal id (plist-get item :id))) threads)
                   (seq-find (lambda (item) (eq (plist-get item :status) 'stopped)) threads))))
    (when (and (integerp (plist-get thread :id)) (eq (plist-get thread :status) 'stopped))
      thread)))

(defun kargu-dape-selection-valid-p (selection)
  "Return non-nil while SELECTION's exact live thread and state remain valid."
  (let* ((conn (kargu-dape-selection-connection selection))
         (thread (kargu-dape-selection-live-thread selection)))
    (and (= (kargu-dape-selection-generation selection) (kargu-dape-event-generation conn))
         (memq thread (kargu-seq-to-list (dape--threads conn)))
         (equal (kargu-dape-selection-thread-id selection) (plist-get thread :id))
         (eq (plist-get thread :status) 'stopped))))

(defun kargu-dape-capture-selection (connection)
  "Capture CONNECTION's current thread and frame identity before any request."
  (let* ((thread (kargu-dape-inspection-thread connection))
         (id (plist-get thread :id)))
    (unless thread (user-error "Inspection requires a live paused selected thread"))
    (kargu-dape--make-selection
     :connection connection :live-thread thread :thread-id id
     :thread (list :id id :name (plist-get thread :name) :status 'stopped
                   :stackFrames nil :totalFrames nil)
     :frame-id (dape--stack-id connection)
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
  (let ((conn (kargu-dape-selection-connection selection)))
    (and (kargu-dape-selection-valid-p selection)
         (eq (kargu-dape-selection-live-thread selection) (kargu-dape-inspection-thread conn))
         (equal (kargu-dape-selection-frame-id selection) (dape--stack-id conn)))))

(provide 'kargu/tools/dape/selection)
;;; selection.el ends here
