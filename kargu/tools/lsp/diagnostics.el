;;; diagnostics.el --- Flymake diagnostics and settling -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Collect, format and asynchronously wait for workspace diagnostics.

;;; Code:

(require 'kargu/tools/lsp/context)
(require 'kargu/tools/lsp/settle)

(declare-function flymake-diagnostic-point "flymake")

;;;; Diagnostics ----------------------------------------------------------

(defun kargu-lsp--diagnostic-severity (type)
  "Normalize diagnostic TYPE through its declared Flymake category."
  (pcase (or (and (symbolp type) (get type 'flymake-category)) type)
    ((or :error 'flymake-error 'e :flymake-error) 1)
    ((or :warning 'flymake-warning 'w :flymake-warning) 2)
    (_ 3)))

(defun kargu-lsp--diagnostic-location (locus position)
  "Return one-based (LINE . COLUMN) for POSITION in LOCUS."
  (cond
   ((and (bufferp locus) (buffer-live-p locus) (number-or-marker-p position))
    (with-current-buffer locus
      (save-excursion
        (save-restriction
          (widen)
          (goto-char position)
          (cons (line-number-at-pos) (1+ (- (point) (line-beginning-position))))))))
   ((consp position) (cons (car position) (or (cdr position) 1)))
   ((numberp position) (cons (if (> position 1000000) 1 position) 1))
   (t '(1 . 1))))

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
                            (location (kargu-lsp--diagnostic-location buffer beg))
                            (type (flymake-diagnostic-type d)))
                       (when beg
                         (list :severity (kargu-lsp--diagnostic-severity type)
                               :line (car location)
                               :character (cdr location)
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
      (let ((key (list (plist-get d :line) (plist-get d :character)
                       (plist-get d :severity) (plist-get d :message))))
        (unless (gethash key seen)
          (puthash key t seen)
          (push d data))))
    (sort (nreverse data)
          (lambda (a b)
            (if (= (plist-get a :severity) (plist-get b :severity))
                (< (plist-get a :line) (plist-get b :line))
              (< (plist-get a :severity) (plist-get b :severity)))))))

(defun kargu-lsp-diagnostics-snapshot (file-path)
  "Return normalized cached diagnostic records for FILE-PATH.
This reads observations only; it does not establish their freshness."
  (kargu-lsp--diagnostics-data file-path))

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
            (format "%s: diagnostics unavailable (file is not open in Emacs; read_file does not start a checker). Open the file in Emacs or run project tests." path))
           ((and (not data) (not (kargu-lsp--buffer-has-checker-p open)))
            (format "%s: diagnostics unavailable (no active Flymake/Eglot checker); run project tests instead." path))
           ((not data)
            (format "%s: no observed diagnostics (cached snapshot; freshness unverified)" path))
           (t (kargu-lsp-format-diagnostics path data)))))
    (when (called-interactively-p 'any)
      (message "%s" text))
    text))

(defun kargu-lsp--flymake-diagnostic-locus (diag)
  "Return Flymake DIAG's locus without inspecting source text."
  (or (and (fboundp 'flymake-diagnostic-buffer) (flymake-diagnostic-buffer diag))
      (and (fboundp 'flymake--diag-locus) (flymake--diag-locus diag))))

(defun kargu-lsp--flymake-diagnostic-file (diag)
  "Return Flymake DIAG's file locus without inspecting source text."
  (let ((locus (kargu-lsp--flymake-diagnostic-locus diag)))
    (cond
     ((bufferp locus) (and (buffer-live-p locus) (buffer-file-name locus)))
     ((stringp locus) locus))))

(defun kargu-lsp--extract-flymake-diag (diag)
  "Extract (:file :severity :line :character :source :message) from Flymake DIAG."
  (let* ((locus (kargu-lsp--flymake-diagnostic-locus diag))
         (file (kargu-lsp--flymake-diagnostic-file diag))
         (beg (if (fboundp 'flymake-diagnostic-beg)
                  (flymake-diagnostic-beg diag)
                (and (fboundp 'flymake-diagnostic-point)
                     (flymake-diagnostic-point diag))))
         (location (kargu-lsp--diagnostic-location locus beg))
         (type (and (fboundp 'flymake-diagnostic-type) (flymake-diagnostic-type diag)))
         (text (and (fboundp 'flymake-diagnostic-text) (flymake-diagnostic-text diag)))
         (backend (and (fboundp 'flymake-diagnostic-backend) (flymake-diagnostic-backend diag)))
         (source (cond
                  ((stringp backend) backend)
                  ((symbolp backend) (symbol-name backend))
                  (t "eglot"))))
    (when (and file text)
      (list :file (expand-file-name file)
            :severity (kargu-lsp--diagnostic-severity type)
            :line (car location)
            :character (cdr location)
            :source source
            :message text))))

(defun kargu-lsp--project-diagnostic-path (path root)
  "Return canonical local PATH within ROOT, or nil before source inspection."
  (when (and (stringp path) (not (string-empty-p path))
             (stringp root) (not (string-empty-p root))
             (not (file-remote-p path)) (not (file-remote-p root)))
    (condition-case nil
        (let ((canonical (file-truename (expand-file-name path root))))
          (when (kargu-permission-within-project-p canonical root) canonical))
      (file-error nil))))

(defun kargu-lsp--native-project-diagnostics (root)
  "Collect only workspace-owned native Flymake diagnostics for ROOT."
  (when (fboundp 'flymake--project-diagnostics)
    (let* ((default-directory root)
           (records (condition-case nil
                        (flymake--project-diagnostics
                         (and (fboundp 'project-current) (project-current nil root)))
                      (error nil)))
           (data nil))
      (dolist (record records)
        (when-let* ((path (kargu-lsp--project-diagnostic-path
                          (kargu-lsp--flymake-diagnostic-file record) root))
                    (extracted (kargu-lsp--extract-flymake-diag record)))
          (push (plist-put extracted :file path) data)))
      data)))

(defun kargu-lsp--collect-project-diagnostics (root)
  "Collect diagnostics for canonical local ROOT from owned files only.
Reject foreign/remote loci before inspecting source buffers or observations."
  (save-match-data
    (when-let* ((canonical (kargu-lsp--project-diagnostic-path root root)))
      (let* ((root (file-name-as-directory canonical))
             (data (kargu-lsp--native-project-diagnostics root)))
        (dolist (buffer (buffer-list))
          (when-let* ((file (buffer-file-name buffer))
                      (path (kargu-lsp--project-diagnostic-path file root)))
            (dolist (diag (kargu-lsp--diagnostics-data file))
              (push (append (list :file path) diag) data))))
        data))))

(defun kargu-lsp--group-diagnostics-by-file (all-diags)
  "Deduplicate and group ALL-DIAGS by file.
Return a list `(TOTAL-COUNT BY-FILE-HASH)'."
  (let ((by-file (make-hash-table :test 'equal))
        (seen (make-hash-table :test 'equal))
        (total-count 0))
    (dolist (d all-diags)
      (let* ((file (plist-get d :file))
             (key (list file (plist-get d :line) (plist-get d :character)
                        (plist-get d :severity) (plist-get d :message))))
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
      (format "[No observed diagnostics] No diagnostics in the available project snapshot (root: %s). Unopened files and unreported checks are not verified; this is not a project-wide build/test result." root)
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

(provide 'kargu/tools/lsp/diagnostics)

;;; diagnostics.el ends here
