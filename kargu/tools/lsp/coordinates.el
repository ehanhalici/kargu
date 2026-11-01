;;; coordinates.el --- Exact live LSP coordinate primitives -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Widened character/UTF code-unit conversion, without rounding or clamping.

;;; Code:

(require 'cl-lib)

(define-error 'kargu-lsp-coordinate-limit "Symbol coordinate capture limit exceeded")
(define-error 'kargu-lsp-coordinate-timeout "Symbol coordinate capture deadline exceeded")
(defvar kargu-lsp-coordinate--remaining nil
  "Optional native budget for actual code-unit character visits.")
(defvar kargu-lsp-coordinate--deadline nil
  "Optional captured native observation deadline; never a freshness heuristic.")
(defvar kargu-lsp-coordinate--lines nil "Optional native cache of exact line beginnings.")
(defvar kargu-lsp-coordinate--cursor nil "Last captured native line and its beginning.")
(defvar kargu-lsp-coordinate--line-remaining nil "Optional native line traversal character budget.")

(defun kargu-lsp-coordinate--check-deadline ()
  "Refuse a captured native observation after its publication deadline."
  (when (and kargu-lsp-coordinate--deadline (>= (float-time) kargu-lsp-coordinate--deadline))
    (signal 'kargu-lsp-coordinate-timeout nil)))

(defun kargu-lsp-coordinate--goto-line (line)
  "Move to exact zero-based LINE, reusing only this native capture's cache."
  (let ((cached (and kargu-lsp-coordinate--lines (gethash line kargu-lsp-coordinate--lines))))
    (if cached (progn (goto-char cached) (setq kargu-lsp-coordinate--cursor (cons line cached)) t)
      (let* ((previous (car-safe kargu-lsp-coordinate--cursor))
             (begin (or (cdr-safe kargu-lsp-coordinate--cursor) (point-min)))
             (delta (- line (or previous 0))))
        (goto-char begin)
        (let ((remaining (forward-line delta)))
          (when kargu-lsp-coordinate--line-remaining
            (cl-decf kargu-lsp-coordinate--line-remaining (abs (- (point) begin)))
            (when (< kargu-lsp-coordinate--line-remaining 0) (signal 'kargu-lsp-coordinate-limit nil)))
          (when (and (= remaining 0) (or (= line 0) (bolp)))
            (when kargu-lsp-coordinate--lines
              (puthash line (point) kargu-lsp-coordinate--lines)
              (setq kargu-lsp-coordinate--cursor (cons line (point))))
            t))))))

(defun kargu-lsp--char-code-units (ch encoding)
  "Return code unit width of character CH in LSP position ENCODING."
  (pcase (or encoding 'utf-16)
    ('utf-16 (if (> ch #xFFFF) 2 1))
    ('utf-8 (string-bytes (char-to-string ch)))
    ('utf-32 1)
    (other (error "Unsupported LSP position encoding: %S" other))))

(defun kargu-lsp--lsp-pos-to-point (line &optional character encoding)
  "Convert 0-based LSP (LINE, CHARACTER) in ENCODING to widened point.
Return nil when LINE or CHARACTER is out of bounds or splits a code unit."
  (kargu-lsp-coordinate--check-deadline)
  (when (and (listp line) (plist-member line :line))
    (setq encoding character
          character (plist-get line :character)
          line (plist-get line :line)))
  (when (and (integerp line) (>= line 0)
             (integerp character) (>= character 0))
    (save-excursion
      (save-restriction
        (widen)
        (when (kargu-lsp-coordinate--goto-line line)
            (let ((line-end (line-end-position))
                  (units 0)
                  (valid t))
              (while (and valid (< units character) (< (point) line-end))
                (when kargu-lsp-coordinate--remaining
                  (when (<= kargu-lsp-coordinate--remaining 0) (signal 'kargu-lsp-coordinate-limit nil))
                  (cl-decf kargu-lsp-coordinate--remaining))
                (let ((step (kargu-lsp--char-code-units (char-after) encoding)))
                  (if (> (+ units step) character)
                      (setq valid nil)
                    (setq units (+ units step))
                    (forward-char 1))))
              (and valid (= units character) (point))))))))

(defun kargu-lsp--point-to-lsp-pos (pos &optional encoding)
  "Convert widened buffer POS to 0-based LSP (:line L :character C) in ENCODING.
Return nil when POS is outside the widened buffer bounds."
  (save-excursion
    (save-restriction
      (widen)
      (when (and (integerp pos) (>= pos (point-min)) (<= pos (point-max)))
        (goto-char pos)
        (let ((line (1- (line-number-at-pos pos t)))
              (line-start (line-beginning-position))
              (units 0))
          (goto-char line-start)
          (while (< (point) pos)
            (setq units (+ units (kargu-lsp--char-code-units (char-after) encoding)))
            (forward-char 1))
          (list :line line :character units))))))

(defun kargu-lsp-coordinate--object (&rest fields)
  "Build a detached wire coordinate object from FIELDS."
  (let ((object (make-hash-table :test #'equal)))
    (while fields (puthash (pop fields) (pop fields) object))
    object))

(defun kargu-lsp-coordinate-position (position)
  "Return widened scalar coordinates for exact buffer POSITION."
  (save-excursion
    (save-restriction
      (widen)
      (unless (and (integerp position) (<= (point-min) position (point-max)))
        (error "Invalid source position"))
      (goto-char position)
      (let* ((end (line-end-position))
             (content-end (if (and (eq (char-after end) ?\n) (eq (char-before end) ?\r)) (1- end) end)))
        (when (> position content-end) (error "Position splits CRLF"))
        (kargu-lsp-coordinate--object "line" (line-number-at-pos position t)
                                      "column" (- position (line-beginning-position)))))))

(defun kargu-lsp-coordinate-point (position)
  "Resolve exact scalar wire POSITION in the widened current buffer."
  (let ((line (and (hash-table-p position) (gethash "line" position)))
        (column (and (hash-table-p position) (gethash "column" position))))
    (unless (and (integerp line) (> line 0) (integerp column) (>= column 0))
      (error "Invalid wire coordinate"))
    (save-excursion
      (save-restriction
        (widen) (goto-char (point-min))
        (unless (= (forward-line (1- line)) 0) (error "Invalid source line"))
        (let* ((end (line-end-position))
               (content-end (if (and (eq (char-after end) ?\n) (eq (char-before end) ?\r)) (1- end) end)))
          (when (> column (- content-end (point))) (error "Invalid scalar column"))
          (+ (point) column))))))

(defun kargu-lsp-coordinate-range (start end)
  "Capture exact widened START/END as an end-exclusive wire range."
  (unless (<= start end) (error "Reversed source range"))
  (kargu-lsp-coordinate--object "start" (kargu-lsp-coordinate-position start)
                                "end" (kargu-lsp-coordinate-position end)))

(provide 'kargu/tools/lsp/coordinates)
;;; coordinates.el ends here
