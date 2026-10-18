;;; bench-process.el --- Reproducible Unicode process-filter benchmark -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Run with: emacs --batch -Q -L . -l tests/bench-process.el
;;           -f kargu-benchmark-process
;; Compare scaling, not absolute timings from different machines.

;;; Code:

(require 'benchmark)
(require 'kargu/tools/process)

(defconst kargu-benchmark--process-chunk (make-string 256 ?ğ)
  "Fixed multibyte chunk used for reproducible append workloads.")

(cl-defun kargu-benchmark--process-case (pieces &key mode repetitions)
  "Measure PIECES of Unicode output using MODE for REPETITIONS trials."
  (let ((chunk kargu-benchmark--process-chunk))
    (garbage-collect)
    (benchmark-run repetitions
      (with-temp-buffer
        (let ((filter (kargu-process--filter
                       (current-buffer) (1+ (* pieces (string-bytes chunk)))
                       (list :truncated nil))))
          (dotimes (_ pieces)
            (pcase mode
              ('filter (funcall filter nil chunk))
              (_ (insert chunk)
                 (when (eq mode 'position) (position-bytes (point-max)))))))))))

(defun kargu-benchmark-process (&optional repetitions)
  "Print Unicode append/filter scaling with REPETITIONS trials, default three."
  (interactive)
  (princ (format "%s\n%d Unicode characters (%d UTF-8 bytes) per chunk\n"
                 (emacs-version) (length kargu-benchmark--process-chunk)
                 (string-bytes kargu-benchmark--process-chunk)))
  (dolist (pieces '(4096 16384 65536))
    (dolist (mode '(insert position filter))
      (princ (format "pieces=%d bytes=%d mode=%s result=%S\n"
                     pieces (* pieces (string-bytes kargu-benchmark--process-chunk)) mode
                     (kargu-benchmark--process-case
                      pieces :mode mode :repetitions (or repetitions 3)))))))

(provide 'tests/bench-process)
;;; bench-process.el ends here
