;;; diagnostics.el --- Flymake diagnostics and settling -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Collect, format and asynchronously wait for workspace diagnostics.

;;; Code:

(require 'kargu/tools/lsp/context)

(declare-function flymake-diagnostic-point "flymake")

;;;; Diagnostics ----------------------------------------------------------

(defun kargu-lsp--flymake-diags (path)
  "Normalized Flymake diagnostics for PATH, or nil."
  (when (and (fboundp 'flymake-diagnostics)
             (fboundp 'flymake-diagnostic-text))
    (let ((buffer (find-buffer-visiting path)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (let ((source (if (kargu-lsp--buffer-managed-p buffer) "eglot" "flymake")))
            (delq nil
                  (mapcar
                   (lambda (d)
                     (let* ((beg (if (fboundp 'flymake-diagnostic-beg)
                                     (flymake-diagnostic-beg d)
                                   (flymake-diagnostic-point d)))
                            (pos (if (consp beg) (car beg) beg))
                            (type (flymake-diagnostic-type d)))
                       (when (number-or-marker-p pos)
                         (list :severity (pcase type
                                           ((or :error 'flymake-error 'e :flymake-error) 1)
                                           ((or :warning 'flymake-warning 'w :flymake-warning) 2)
                                           (_ 3))
                               :line (line-number-at-pos pos)
                               :character 1
                               :source source
                               :message (flymake-diagnostic-text d)))))
                   (flymake-diagnostics)))))))))

(defun kargu-lsp--diagnostics-data (file-path)
  "Return normalized diagnostics for FILE-PATH.
Sort records by severity and then line number."
  (let* ((path (kargu-permission-resolve file-path "lsp path"))
         (combined (kargu-lsp--flymake-diags path))
         (seen (make-hash-table :test 'equal))
         (data nil))
    (dolist (d combined)
      (let ((key (format "%s:%s:%s"
                         (plist-get d :line)
                         (plist-get d :severity)
                         (plist-get d :message))))
        (unless (gethash key seen)
          (puthash key t seen)
          (push d data))))
    (sort (nreverse data)
          (lambda (a b)
            (if (= (plist-get a :severity) (plist-get b :severity))
                (< (plist-get a :line) (plist-get b :line))
              (< (plist-get a :severity) (plist-get b :severity)))))))

(defun kargu-lsp--severity-label (severity)
  "Return a short label for LSP diagnostic SEVERITY."
  (pcase severity
    (1 "error") (2 "warning") (3 "info") (4 "hint")
    (_ "note")))

(defun kargu-lsp-format-diagnostics (file-path data)
  "Render diagnostic DATA for FILE-PATH as text."
  (if (null data)
      (format "%s: no diagnostics (clean)" file-path)
    (concat
     (format "%s — %d diagnostic(s)\n" file-path (length data))
     (mapconcat
      (lambda (d)
        (format "  [%s] L%d:C%d: %s%s"
                (kargu-lsp--severity-label (plist-get d :severity))
                (plist-get d :line)
                (plist-get d :character)
                (plist-get d :message)
                (if (plist-get d :source)
                    (format " (source: %s)" (plist-get d :source))
                  "")))
      data "\n"))))

(defun kargu-lsp-get-diagnostics (file-path)
  "Return a text report of diagnostics for FILE-PATH."
  (interactive (list (read-file-name "Diagnostics for file: ")))
  (let* ((path (kargu-permission-resolve file-path "lsp path"))
         (open (find-buffer-visiting path))
         (data (kargu-lsp--diagnostics-data path))
         (text
          (cond
           ((and (not data) (not open))
            (format "%s: no diagnostics available (file is not open in Emacs; open it or use read_file first)" path))
           (t (kargu-lsp-format-diagnostics path data)))))
    (when (called-interactively-p 'any)
      (message "%s" text))
    text))

(defun kargu-lsp--diagnostic-line (locus pos)
  "Return the line number of diagnostic POS in LOCUS."
  (cond
   ((and (bufferp locus) (buffer-live-p locus) (number-or-marker-p pos))
    (with-current-buffer locus
      (save-excursion
        (goto-char (if (markerp pos) (marker-position pos) pos))
        (line-number-at-pos))))
   ((numberp pos) (if (> pos 1000000) 1 pos))
   (t 1)))

(defun kargu-lsp--extract-flymake-diag (diag)
  "Extract (:file :severity :line :character :source :message) from Flymake DIAG."
  (let* ((locus (or (and (fboundp 'flymake-diagnostic-buffer)
                         (flymake-diagnostic-buffer diag))
                    (and (fboundp 'flymake--diag-locus)
                         (flymake--diag-locus diag))))
         (file (cond
                ((bufferp locus)
                 (when (buffer-live-p locus)
                   (or (buffer-file-name locus) (buffer-name locus))))
                ((stringp locus) locus)
                (t nil)))
         (beg (if (fboundp 'flymake-diagnostic-beg)
                  (flymake-diagnostic-beg diag)
                (and (fboundp 'flymake-diagnostic-point)
                     (flymake-diagnostic-point diag))))
         (pos (if (consp beg) (car beg) beg))
         (line (kargu-lsp--diagnostic-line locus pos))
         (type (and (fboundp 'flymake-diagnostic-type) (flymake-diagnostic-type diag)))
         (text (and (fboundp 'flymake-diagnostic-text) (flymake-diagnostic-text diag)))
         (backend (and (fboundp 'flymake-diagnostic-backend) (flymake-diagnostic-backend diag)))
         (source (cond
                  ((stringp backend) backend)
                  ((symbolp backend) (symbol-name backend))
                  (t "eglot"))))
    (when (and file text)
      (list :file (expand-file-name file)
            :severity (pcase type
                        ((or :error 'flymake-error 'e :flymake-error) 1)
                        ((or :warning 'flymake-warning 'w :flymake-warning) 2)
                        (_ 3))
            :line line
            :character 1
            :source source
            :message text))))

(defun kargu-lsp--collect-project-diagnostics (root)
  "Collect raw diagnostics across the project ROOT from Flymake and open buffers.
Nil when ROOT is not a directory string."
  (if (not (stringp root))
      nil
    (let* ((all-diags nil)
           (flymake-proj (when (fboundp 'flymake--project-diagnostics)
                           (condition-case _err
                               (let ((default-directory root))
                                 (flymake--project-diagnostics
                                  (and (fboundp 'project-current)
                                       (project-current nil root))))
                             (error nil))))
           (open-proj-diags
            (cl-loop for buf in (buffer-list)
                     for fn = (buffer-file-name buf)
                     when (and fn (string-prefix-p root (expand-file-name fn)))
                     append (cl-loop for d in (kargu-lsp--diagnostics-data fn)
                                     collect (append (list :file (expand-file-name fn)) d)))))
      (dolist (d flymake-proj)
        (let ((extracted (kargu-lsp--extract-flymake-diag d)))
          (when extracted
            (push extracted all-diags))))
      (dolist (d open-proj-diags)
        (push d all-diags))
      all-diags)))

(defun kargu-lsp--group-diagnostics-by-file (all-diags)
  "Deduplicate and group ALL-DIAGS by file.
Return a list `(TOTAL-COUNT BY-FILE-HASH)'."
  (let ((by-file (make-hash-table :test 'equal))
        (seen (make-hash-table :test 'equal))
        (total-count 0))
    (dolist (d all-diags)
      (let* ((file (plist-get d :file))
             (key (format "%s:%s:%s:%s"
                          file
                          (plist-get d :line)
                          (plist-get d :severity)
                          (plist-get d :message))))
        (unless (gethash key seen)
          (puthash key t seen)
          (cl-incf total-count)
          (puthash file (cons d (gethash file by-file)) by-file))))
    (list total-count by-file)))

(defun kargu-lsp--format-file-diagnostic-section (root file items)
  "Format diagnostic ITEMS for FILE relative to ROOT."
  (let* ((sorted-items
          (sort (copy-sequence items)
                (lambda (a b)
                  (if (= (plist-get a :severity) (plist-get b :severity))
                      (< (plist-get a :line) (plist-get b :line))
                    (< (plist-get a :severity) (plist-get b :severity))))))
         (err-count (cl-count-if (lambda (d) (= (plist-get d :severity) 1)) sorted-items))
         (warn-count (cl-count-if (lambda (d) (= (plist-get d :severity) 2)) sorted-items))
         (rel-file (if (string-prefix-p root file)
                       (substring file (length root))
                     file)))
    (concat
     (format "== %s (%d diagnostic%s%s) ==\n"
             rel-file
             (length sorted-items)
             (if (= (length sorted-items) 1) "" "s")
             (cond
              ((and (> err-count 0) (> warn-count 0))
               (format ": %d error%s, %d warning%s"
                       err-count (if (= err-count 1) "" "s")
                       warn-count (if (= warn-count 1) "" "s")))
              ((> err-count 0)
               (format ": %d error%s" err-count (if (= err-count 1) "" "s")))
              ((> warn-count 0)
               (format ": %d warning%s" warn-count (if (= warn-count 1) "" "s")))
              (t "")))
     (mapconcat
      (lambda (d)
        (format "  [%s] L%d:C%d: %s%s"
                (kargu-lsp--severity-label (plist-get d :severity))
                (plist-get d :line)
                (plist-get d :character)
                (plist-get d :message)
                (if (plist-get d :source)
                    (format " (source: %s)" (plist-get d :source))
                  "")))
      sorted-items "\n"))))

(defun kargu-lsp--format-project-diagnostics (root total-count by-file)
  "Format aggregated diagnostics for ROOT given TOTAL-COUNT and BY-FILE table."
  (if (zerop total-count)
      (format "[Project Clean] No compile or linter diagnostics found across the project (root: %s)." root)
    (let* ((files (hash-table-keys by-file))
           (sorted-files
            (sort files
                  (lambda (a b)
                    (let ((a-has-err (cl-some (lambda (d) (= (plist-get d :severity) 1)) (gethash a by-file)))
                          (b-has-err (cl-some (lambda (d) (= (plist-get d :severity) 1)) (gethash b by-file))))
                      (cond
                       ((and a-has-err (not b-has-err)) t)
                       ((and (not a-has-err) b-has-err) nil)
                       (t (string< a b)))))))
           (sections
            (mapcar (lambda (f)
                      (kargu-lsp--format-file-diagnostic-section root f (gethash f by-file)))
                    sorted-files)))
      (concat
       (format "Project diagnostics (root: %s) — %d diagnostic%s across %d file%s:\n\n"
               root total-count (if (= total-count 1) "" "s")
               (length sorted-files) (if (= (length sorted-files) 1) "" "s"))
       (string-join sections "\n\n")))))

(defun kargu-lsp-get-project-diagnostics ()
  "Scan and return a text report of diagnostics across the entire project.
Aggregates diagnostics from Flymake project diagnostics and all open
project buffers."
  (interactive)
  (let* ((root (kargu-lsp-project-root))
         (all-diags (kargu-lsp--collect-project-diagnostics root))
         (grouped (kargu-lsp--group-diagnostics-by-file all-diags))
         (total-count (nth 0 grouped))
         (by-file (nth 1 grouped))
         (text (kargu-lsp--format-project-diagnostics root total-count by-file)))
    (when (called-interactively-p 'any)
      (message "%s" text))
    text))

(defun kargu-lsp--buffer-has-checker-p (buf)
  "Return non-nil if BUF has Flymake or an Eglot-managed syntax checker."
  (and buf (buffer-live-p buf)
       (or (kargu-lsp--buffer-managed-p buf)
           (with-current-buffer buf
             (bound-and-true-p flymake-mode)))))

(defun kargu-lsp--checker-busy-p (buf)
  "Return non-nil if Flymake is currently running on BUF."
  (and buf (buffer-live-p buf)
       (with-current-buffer buf
         (and (bound-and-true-p flymake-mode)
              (fboundp 'flymake-is-running)
              (flymake-is-running)))))

(defun kargu-lsp-wait-diagnostics (file-path callback &optional timeout)
  "Wait asynchronously for FILE-PATH diagnostics and invoke CALLBACK.
Stop after TIMEOUT seconds, or use `kargu-lsp-diag-settle-timeout'."
  (let* ((path (kargu-permission-resolve file-path "lsp path"))
         (buf (find-buffer-visiting path))
         (has-checker-p (kargu-lsp--buffer-has-checker-p buf))
         (timeout (or timeout kargu-lsp-diag-settle-timeout))
         (start (float-time))
         (last-snapshot nil)
         (polls 0))
    (if (not has-checker-p)
        (funcall callback path (kargu-lsp-get-diagnostics path) nil)
      (cl-labels
          ((tick ()
             (let* ((busy (kargu-lsp--checker-busy-p buf))
                    (timed-out (>= (- (float-time) start) timeout))
                    (snapshot (kargu-lsp--diagnostics-data path)))
               (setq polls (1+ polls))
               (if (or timed-out
                       (and (not busy) (>= polls 1) (null snapshot))
                       (and (not busy) (>= polls 2) (equal snapshot last-snapshot)))
                   (funcall callback path (kargu-lsp-get-diagnostics path) timed-out)
                 (setq last-snapshot snapshot)
                 (run-at-time 0.25 nil #'tick)))))
        (run-at-time 0.25 nil #'tick)))))

(provide 'kargu/tools/lsp/diagnostics)

;;; diagnostics.el ends here
