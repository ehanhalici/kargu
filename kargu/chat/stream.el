;;; stream.el --- Chat streaming text and thoughts -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Render answer and reasoning deltas in the active chat buffer.

;;; Code:

(require 'kargu/chat/transcript)

(defcustom kargu-chat-drop-preamble nil
  "When non-nil, delete assistant text that preceded a tool call.
When nil (default), pre-tool explanations are kept in the chat
transcript above the tool activity lines."
  :type 'boolean
  :group 'kargu-ui)

(defvar-local kargu-chat--streamed-text nil
  "Whether the current run has streamed any answer text.
When the plain (non-streaming) transport is used, the final answer
arrives only with the run report; the chat then prints it once
instead of relying on deltas.")

(defvar-local kargu-chat--in-thought nil
  "Non-nil when currently streaming thought/reasoning tokens.")

(defvar-local kargu-chat--answer-start nil
  "Marker at the start of streamed assistant text for the current turn.")

(defvar-local kargu-chat--preamble-dropped nil
  "Non-nil after streamed CoT was removed because a tool call started.")

(defvar-local kargu-chat--thought-pending ""
  "Incomplete reasoning marker held until the next streaming fragment.")

(defun kargu-chat--on-delta (text &optional kind)
  "Append one streamed TEXT fragment of the assistant answer.
KIND may be `thought' when streaming reasoning tokens.  The stream flags
are buffer-local, so the fragment is handled inside the run's chat buffer
whatever buffer is current when the process filter fires."
  (save-match-data
    (let ((buffer (kargu-chat-output-buffer)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (kargu-chat--stream-delta text kind))))))

(defconst kargu-chat--thought-open "<think>"
  "Opening marker for inline reasoning.")

(defconst kargu-chat--thought-close "</think>"
  "Closing marker for inline reasoning.")

(defun kargu-chat--stream-delta (text kind)
  "Render streamed TEXT of KIND in the current chat buffer."
  (when (and (stringp text) (not (string-empty-p text))
             (not kargu-chat--preamble-dropped))
    (unless kargu-chat--streamed-text
      (setq kargu-chat--thought-pending ""))
    (setq kargu-chat--streamed-text t)
    (if (eq kind 'thought)
        (kargu-chat-insert text 'kargu-chat-thought)
      (kargu-chat--stream-tagged-text text))))

(defun kargu-chat--next-thought-tag (text start)
  "Return the next reasoning marker in TEXT from START as (POSITION . TAG)."
  (let ((open (string-search kargu-chat--thought-open text start))
        (close (string-search kargu-chat--thought-close text start)))
    (cond
     ((and open (or (null close) (< open close)))
      (cons open kargu-chat--thought-open))
     (close (cons close kargu-chat--thought-close)))))

(defun kargu-chat--insert-stream-text (text)
  "Insert TEXT using the current reasoning face."
  (unless (string-empty-p text)
    (kargu-chat-insert text (and kargu-chat--in-thought 'kargu-chat-thought))))

(defun kargu-chat--stream-tagged-text (text)
  "Render TEXT while switching faces at each inline reasoning marker."
  (setq text (concat kargu-chat--thought-pending text)
        kargu-chat--thought-pending "")
  (let ((start 0) marker)
    (while (setq marker (kargu-chat--next-thought-tag text start))
      (kargu-chat--insert-stream-text (substring text start (car marker)))
      (setq kargu-chat--in-thought
            (equal (cdr marker) kargu-chat--thought-open)
            start (+ (car marker) (length (cdr marker)))))
    (let* ((tail (substring text start))
           (pending (kargu-chat--thought-prefix-length tail)))
      (setq kargu-chat--thought-pending (substring tail (- (length tail) pending)))
      (kargu-chat--insert-stream-text (substring tail 0 (- (length tail) pending))))))

(defun kargu-chat--thought-prefix-length (text)
  "Return the length of TEXT's longest suffix beginning a reasoning marker."
  (let ((size (min (length text) (1- (length kargu-chat--thought-close)))))
    (while (and (> size 0)
                (not (or (string-prefix-p (substring text (- (length text) size))
                                          kargu-chat--thought-open)
                         (string-prefix-p (substring text (- (length text) size))
                                          kargu-chat--thought-close))))
      (setq size (1- size)))
    size))

(defun kargu-chat-flush-stream ()
  "Render a trailing incomplete marker in the current chat buffer."
  (unless (string-empty-p kargu-chat--thought-pending)
    (kargu-chat--insert-stream-text kargu-chat--thought-pending)
    (setq kargu-chat--thought-pending "")))

(defun kargu-chat--drop-streamed-preamble ()
  "Delete streamed assistant text that preceded the first tool call.
Only used when `kargu-chat-drop-preamble' is non-nil."
  (when kargu-chat-drop-preamble
    (let ((buffer (kargu-chat-output-buffer)))
      (when (and (buffer-live-p buffer)
                 (buffer-local-value 'kargu-chat--answer-start buffer)
                 (not (buffer-local-value 'kargu-chat--preamble-dropped buffer))
                 (eq (marker-buffer (buffer-local-value 'kargu-chat--answer-start buffer))
                     buffer))
        (with-current-buffer buffer
          (let* ((inhibit-read-only t)
                 (beg (marker-position kargu-chat--answer-start))
                 (end (and (markerp kargu-chat--output-marker)
                           (eq (marker-buffer kargu-chat--output-marker)
                               buffer)
                           (marker-position kargu-chat--output-marker))))
            (when (and beg end (> end beg))
              (delete-region beg end))
            (setq kargu-chat--streamed-text nil
                  kargu-chat--thought-pending ""
                  kargu-chat--preamble-dropped t)))))))

(provide 'kargu/chat/stream)

;;; stream.el ends here
