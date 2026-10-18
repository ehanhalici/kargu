;;; render.el --- Debug snapshot formatting -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Format stack frames, scopes and variable values for the model.

;;; Code:

(require 'kargu/tools/dape/session)
(require 'ansi-color)
(require 'rx)

;;;; Rendering helpers -----------------------------------------------------

(defconst kargu-dape--osc-pattern
  (rx "\e]" (*? anychar) (or "\a" "\e\\"))
  "Terminal operating-system commands, terminated by BEL or ST.")

(defun kargu-dape--plain-text (text)
  "Strip terminal color and control sequences from adapter TEXT."
  (save-match-data
    (let ((ansi-color-context nil))
      (ansi-color-filter-apply
       (replace-regexp-in-string kargu-dape--osc-pattern "" (or text "") t t)))))

(defun kargu-dape--trunc (string)
  "Truncate a variable value STRING for the model."
  (let ((one-line (replace-regexp-in-string
                   "\n" "\\\\n" (kargu-dape--plain-text string))))
    (truncate-string-to-width one-line
                              kargu-dape-variable-value-width)))

(defun kargu-dape--frame-path (conn frame)
  "Return FRAME's local file path using CONN's path mapping."
  (let ((path (plist-get (plist-get frame :source) :path)))
    (cond
     ((null path) "?")
     ((fboundp 'dape--file-name-local) (dape--file-name-local conn path))
     (t path))))

(defun kargu-dape--format-var-line (v &optional indent)
  "Format variable V as a text line with optional INDENT."
  (let ((pad (or indent "  "))
        (vref (plist-get v :variablesReference)))
    (format "%s%s = %s%s"
            pad
            (kargu-dape--plain-text (or (plist-get v :name) "?"))
            (kargu-dape--trunc (or (plist-get v :value) "?"))
            (if (and (numberp vref) (not (zerop vref))) " {...}" ""))))

(defun kargu-dape--render-stack-frames (conn frames frame)
  "Render FRAMES from CONN, highlighting the selected FRAME."
  (let ((lines (list "## Stack")))
    (if (null frames)
        (push "  (no stack frames available)" lines)
      (let ((selected-id (and frame (plist-get frame :id))))
        (cl-loop for f in (seq-take frames kargu-dape-max-frames)
                 for i from 0
                 do (push (format "  #%d %s  (%s:%s)%s"
                                  i
                                  (or (plist-get f :name) "?")
                                  (kargu-dape--frame-path conn f)
                                  (or (plist-get f :line) "?")
                                  (if (eq (plist-get f :id) selected-id)
                                      "  <= selected"
                                    ""))
                          lines)))
      (let ((hidden (- (length frames) kargu-dape-max-frames)))
        (when (> hidden 0)
          (push (format "  ... %d more frames" hidden) lines))))
    (nreverse lines)))

(defun kargu-dape--render-frame-variables (conn frame)
  "Render variable lines for FRAME using CONN."
  (when frame
    (let* ((lines (list (format "## Variables in frame \"%s\" (%s:%s)"
                                (or (plist-get frame :name) "?")
                                (kargu-dape--frame-path conn frame)
                                (or (plist-get frame :line) "?"))))
           (scopes (seq-take
                    (kargu-dape--seq->list (plist-get frame :scopes))
                    kargu-dape-max-scopes)))
      (if (null scopes)
          (push "  (no scopes reported by the adapter)" lines)
        (dolist (scope scopes)
          (let ((variables (kargu-dape--seq->list (plist-get scope :variables))))
            (push (format "  Scope %s:" (or (plist-get scope :name) "?")) lines)
            (if (null variables)
                (push "    (empty)" lines)
              (dolist (variable (seq-take variables kargu-dape-max-variables))
                (push (kargu-dape--format-var-line variable "    ") lines)))
            (let ((hidden (- (length variables) kargu-dape-max-variables)))
              (when (> hidden 0)
                (push (format "    ... %d more variables" hidden) lines)))))
        (let ((hidden (- (length (kargu-dape--seq->list (plist-get frame :scopes)))
                         kargu-dape-max-scopes)))
          (when (> hidden 0)
            (push (format "  ... %d more scopes" hidden) lines))))
      (nreverse lines))))

(defun kargu-dape--render-context (conn thread frames frame)
  "Render THREAD, FRAMES and selected FRAME from CONN."
  (let* ((header (format "# dape session — thread #%s (%s), %d frame(s)"
                         (or (and thread (plist-get thread :id)) "?")
                         (or (and thread (plist-get thread :status)) "?")
                         (length (or frames nil))))
         (stack-lines (kargu-dape--render-stack-frames conn frames frame))
         (var-lines (kargu-dape--render-frame-variables conn frame))
         (all-lines (cons header (append stack-lines var-lines))))
    (kargu-dape--plain-text (string-join all-lines "\n"))))

(provide 'kargu/tools/dape/render)

;;; render.el ends here
