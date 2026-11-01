;;; snapshot.el --- Bounded live text capture for native readers -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Raw RAM facts shared by standalone and parent-run native reads.  Line motion
;; preserves the editor's narrowing and point; Rust owns rendering and limits.

;;; Code:

(require 'kargu/bridge)

(defun kargu-file-capture-live (buffer from scan-chars output-chars)
  "Capture BUFFER from line FROM within SCAN-CHARS and OUTPUT-CHARS.
Return raw source facts; retain neither buffer text nor mutable editor state."
  (unless (and (buffer-live-p buffer) (integerp from) (> from 0)
               (natnump scan-chars) (<= scan-chars (* 64 1024 1024))
               (natnump output-chars) (<= output-chars 131072))
    (error "Invalid native live capture bounds"))
  (with-current-buffer buffer
    (save-excursion
      (save-restriction
        (widen)
        (let* ((end (point-max))
               (scan-end (min end (+ (point-min) scan-chars)))
               (probe (buffer-substring-no-properties (point-min) (min end (+ (point-min) 1000)))))
          (narrow-to-region (point-min) scan-end)
          (goto-char (point-min))
          (let* ((available (and (zerop (forward-line (1- from)))
                                 (or (= from 1) (< (point) (point-max)))))
                 (finish (min (point-max) (+ (point) (1+ output-chars)))))
            (kargu-bridge--object
             "kind" "editor" "probe" probe
             "from_available" (if available t :json-false)
             "complete" (if (= finish end) t :json-false)
             "text" (if available (buffer-substring-no-properties (point) finish) ""))))))))

(provide 'kargu/files/snapshot)
;;; snapshot.el ends here
