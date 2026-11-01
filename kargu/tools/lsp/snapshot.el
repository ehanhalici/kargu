;;; snapshot.el --- Raw document symbols from captured live providers -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Capture provider identity and scalar ranges.  Name selection, ambiguity,
;; source slicing policy and rendering belong to Rust.  No formatted/cache path.

;;; Code:

(require 'cl-lib)
(require 'imenu)
(require 'kargu/tools/lsp/context)
(require 'kargu/tools/lsp/coordinates)
(require 'kargu/bridge)

(declare-function eglot--signal-textDocument/didChange "eglot" ())
(declare-function eglot-server-capable "eglot" (&rest capabilities))
(declare-function jsonrpc-running-p "jsonrpc" (connection))
(declare-function jsonrpc--process "jsonrpc" (connection))
(declare-function jsonrpc-async-request "jsonrpc" (connection method params &rest arguments))
(defvar eglot--versioned-identifier)
(defvar eglot-current-linepos-function)

(defconst kargu-lsp-snapshot--items 2048 "Maximum captured symbol nodes.")
(defconst kargu-lsp-snapshot--depth 16 "Maximum captured symbol depth.")
(defconst kargu-lsp-snapshot--bytes (* 128 1024) "Maximum serialized symbol metadata bytes.")
(defconst kargu-lsp-snapshot--text-bytes (* 16 1024) "Maximum captured symbol body UTF-8 bytes.")
(defconst kargu-lsp-snapshot--coordinate-work (* 64 1024)
  "Maximum code-unit character visits while converting one native symbol tree.")
(defconst kargu-lsp-snapshot--line-work (* 8 1024 1024)
  "Maximum source characters traversed by native line navigation.")
(defvar kargu-lsp-snapshot--servers (make-hash-table :test #'eq :weakness 'key)
  "Opaque identities for actual live Eglot objects.")
(defvar-local kargu-lsp-snapshot--imenu nil
  "Major mode, imenu provider function and its opaque captured identity.")

(defun kargu-lsp-snapshot--encoding ()
  "Return the active Eglot code-unit encoding, refusing unknown converters."
  (pcase eglot-current-linepos-function
    ('eglot-utf-8-linepos "utf-8") ('eglot-utf-16-linepos "utf-16") ('eglot-utf-32-linepos "utf-32")
    (_ (error "Unsupported Eglot position converter"))))

(defun kargu-lsp-snapshot-source (&optional flush)
  "Capture this buffer's exact language provider; FLUSH sends pending changes."
  (let ((server (and (not (derived-mode-p 'emacs-lisp-mode))
                     (bound-and-true-p eglot--managed-mode)
                     (eglot-current-server))))
    (if (and server (jsonrpc-running-p server) (eglot-server-capable :documentSymbolProvider))
        (progn
          (when flush (eglot--signal-textDocument/didChange))
          (unless (and (integerp eglot--versioned-identifier) (>= eglot--versioned-identifier 0))
            (error "Missing Eglot document version"))
          (let* ((process (jsonrpc--process server))
                 (entry (gethash server kargu-lsp-snapshot--servers))
                 (identity (if (eq process (car-safe entry)) (cdr entry)
                             (cdr (puthash server (cons process (concat "eglot_" (kargu-random-uuid)))
                                           kargu-lsp-snapshot--servers)))))
            (kargu-bridge--object "kind" "eglot" "server" identity "version" eglot--versioned-identifier
                                  "encoding" (kargu-lsp-snapshot--encoding))))
      (unless (and (functionp imenu-create-index-function)
                   (or (not (eq imenu-create-index-function #'imenu-default-create-index-function))
                       imenu-generic-expression (functionp imenu-prev-index-position-function)))
        (error "No symbol provider available"))
      (unless (and (eq (nth 0 kargu-lsp-snapshot--imenu) major-mode)
                   (eq (nth 1 kargu-lsp-snapshot--imenu) imenu-create-index-function)
                   (eq (nth 3 kargu-lsp-snapshot--imenu) (indirect-function imenu-create-index-function)))
        (setq kargu-lsp-snapshot--imenu
              (list major-mode imenu-create-index-function (concat "imenu_" (kargu-random-uuid))
                    (indirect-function imenu-create-index-function))))
      (kargu-bridge--object "kind" "imenu" "provider" (nth 2 kargu-lsp-snapshot--imenu)))))

(defun kargu-lsp-snapshot--kind (number)
  "Convert an exact LSP kind NUMBER to the closed wire enum."
  (let ((kinds ["unknown" "file" "module" "namespace" "package" "class" "method" "property" "field"
                        "constructor" "enum" "interface" "function" "variable" "constant" "string" "number"
                        "boolean" "array" "object" "key" "null" "enum_member" "struct" "event" "operator" "type_parameter"]))
    (if (and (integerp number) (<= 1 number 26)) (aref kinds number) "unknown")))

(defun kargu-lsp-snapshot--position (position encoding)
  "Convert raw LSP POSITION under captured ENCODING without clamping."
  (let ((point (kargu-lsp--lsp-pos-to-point
                (kargu-lsp--field position :line) (kargu-lsp--field position :character)
                (pcase encoding ("utf-8" 'utf-8) ("utf-16" 'utf-16) ("utf-32" 'utf-32)
                       (_ (error "Unknown position encoding"))))))
    (unless point (error "Invalid LSP code-unit coordinate"))
    (kargu-lsp-coordinate-position point)))

(defun kargu-lsp-snapshot--range (range encoding)
  "Capture complete LSP RANGE in ENCODING as scalar coordinates."
  (let* ((start (kargu-lsp-snapshot--position (kargu-lsp--field range :start) encoding))
         (end (kargu-lsp-snapshot--position (kargu-lsp--field range :end) encoding)))
    (unless (or (< (gethash "line" start) (gethash "line" end))
                (and (= (gethash "line" start) (gethash "line" end))
                     (<= (gethash "column" start) (gethash "column" end))))
      (error "Reversed LSP range"))
    (kargu-bridge--object "start" start "end" end)))

(defun kargu-lsp-snapshot--name (name)
  "Validate a bounded raw symbol NAME without replacing invalid characters."
  (unless (and (stringp name) (> (length name) 0) (<= (string-bytes name) 1024)
               (not (string-match-p "[[:cntrl:]]" name)))
    (error "Invalid symbol name"))
  (substring-no-properties name))

(defun kargu-lsp-snapshot--symbols (raw source)
  "Detach bounded LSP documentSymbol RAW under exact captured SOURCE."
  (let ((count 0) truncated)
    (cl-labels ((nodes (items depth)
                  (let (result)
                    (catch 'bounded
                     (seq-doseq (item items)
                      (if (or (> depth kargu-lsp-snapshot--depth) (>= count kargu-lsp-snapshot--items))
                          (progn (setq truncated t) (throw 'bounded nil))
                        (cl-incf count)
                        (let* ((location (kargu-lsp--field item :location))
                               (uri (and location (kargu-lsp--field location :uri)))
                               (range (or (kargu-lsp--field item :range) (kargu-lsp--field location :range)))
                               (selection (kargu-lsp--field item :selectionRange))
                               (encoding (gethash "encoding" source)))
                          (when (and uri (not (equal uri (kargu-lsp--buffer-uri (current-buffer)))))
                            (error "Foreign symbol location"))
                          (push (kargu-bridge--object
                                 "name" (kargu-lsp-snapshot--name (kargu-lsp--field item :name))
                                 "kind" (kargu-lsp-snapshot--kind (kargu-lsp--field item :kind))
                                 "range" (kargu-lsp-snapshot--range range encoding)
                                 "selection_range" (if selection (kargu-lsp-snapshot--range selection encoding) :json-null)
                                 "children" (nodes (kargu-lsp--field item :children) (1+ depth))) result)))))
                    (vconcat (nreverse result)))))
      (let ((symbols (nodes raw 0)))
        (kargu-bridge--object "symbols" symbols "truncated" (if truncated t :json-false))))))

(defun kargu-lsp-snapshot--imenu-symbols ()
  "Capture raw local index positions and actual definition bounds."
  (save-excursion
    (save-restriction
      (widen)
      ;; The menu helper reuses imenu--index-alist and truncates identifiers.
      ;; Capture the provider directly, without touching its displayed index.
      (let* ((index (funcall imenu-create-index-function))
             (stack (and index (list (cons index 0))))
            result truncated (count 0))
        (while stack
          (pcase-let* ((`(,items . ,depth) (pop stack)) (item (car items))
                       (name (car-safe item)) (value (cdr-safe item)))
            (when (cdr items) (push (cons (cdr items) depth) stack))
            (when item
              (cond
               ((or (>= count kargu-lsp-snapshot--items) (> depth kargu-lsp-snapshot--depth)) (setq truncated t stack nil))
               ((imenu--subalist-p item) (push (cons value (1+ depth)) stack))
               (t
                (let* ((value (if (consp value) (car value) value))
                       (position (cond ((markerp value)
                                        (unless (eq (marker-buffer value) (current-buffer)) (error "Foreign imenu marker"))
                                        (marker-position value))
                                       ((integerp value) value))))
                  (unless (and position (<= (point-min) position (point-max))) (error "Invalid imenu position"))
                  (goto-char position)
                  (let ((kind (cond ((looking-at-p "[ \t]*(\\(?:cl-\\)?def\\(?:un\\|macro\\|subst\\)\\_>") "function")
                                    ((looking-at-p "[ \t]*(def\\(?:var\\|custom\\|const\\)\\_>") "variable")
                                    ((looking-at-p "[ \t]*(\\(?:defclass\\|cl-defstruct\\)\\_>") "class") (t "unknown"))))
                    (end-of-defun)
                    (unless (> (point) position) (error "Definition extent unavailable"))
                    (cl-incf count)
                    (push (kargu-bridge--object "name" (kargu-lsp-snapshot--name name) "kind" kind
                                                "range" (kargu-lsp-coordinate-range position (point)) "children" []) result))))))))
        (kargu-bridge--object "symbols" (vconcat (nreverse result)) "truncated" (if truncated t :json-false))))))

(defun kargu-lsp-snapshot-limit (symbols maximum)
  "Return SYMBOLS with at most MAXIMUM nodes and explicit truncation."
  (let ((count 0))
    (cl-labels ((nodes (items)
                  (let (result)
                    (catch 'bounded
                      (seq-doseq (item items)
                        (when (>= count maximum) (throw 'bounded nil))
                        (cl-incf count)
                        (let ((copy (copy-hash-table item)))
                          (puthash "children" (nodes (gethash "children" item)) copy)
                          (push copy result))))
                    (vconcat (nreverse result)))))
      (kargu-bridge--object "symbols" (nodes (gethash "symbols" symbols)) "truncated" t))))

(defun kargu-lsp-snapshot-capture (buffer source callback timeout-ms)
  "Capture BUFFER's raw symbols under SOURCE; always call CALLBACK once.
CALLBACK receives (SYMBOLS FAILURE).  TIMEOUT-MS is captured by the native run.
Its lifetime is independent of Elisp runs;
native issuance retains the actual callback through owner cancellation."
  (let ((delivered nil)
        (deadline (and (integerp timeout-ms) (<= 1 timeout-ms 30000) (+ (float-time) (/ timeout-ms 1000.0)))))
    (cl-labels ((finish (value failure)
                  (unless delivered (setq delivered t) (funcall callback value failure)))
                (capture (raw)
                  (unless delivered
                   (condition-case nil
                      (with-current-buffer buffer
                        (let ((kargu-lsp-coordinate--remaining kargu-lsp-snapshot--coordinate-work)
                              (kargu-lsp-coordinate--deadline deadline)
                              (kargu-lsp-coordinate--lines (make-hash-table :test #'eql))
                              (kargu-lsp-coordinate--cursor (cons 0 1))
                              (kargu-lsp-coordinate--line-remaining kargu-lsp-snapshot--line-work))
                          (kargu-lsp-coordinate--check-deadline)
                          (save-excursion (save-restriction (widen)
                            (let ((symbols (kargu-lsp-snapshot--symbols raw source)))
                              (kargu-lsp-coordinate--check-deadline) (finish symbols nil))))))
                    (quit (finish nil 'cancelled))
                    (kargu-lsp-coordinate-limit (finish nil 'resource_limit))
                    (kargu-lsp-coordinate-timeout (finish nil 'timeout))
                    (error (finish nil 'invalid_range))))))
      (condition-case nil
          (with-current-buffer buffer
            (unless (and (integerp timeout-ms) (<= 1 timeout-ms 30000)) (error "Invalid captured LSP timeout"))
            (pcase (gethash "kind" source)
              ("imenu"
               (let ((kargu-lsp-coordinate--deadline deadline))
                 (kargu-lsp-coordinate--check-deadline)
                 (let ((symbols (kargu-lsp-snapshot--imenu-symbols)))
                   (kargu-lsp-coordinate--check-deadline) (finish symbols nil))))
              ("eglot"
               (jsonrpc-async-request
                (eglot-current-server) :textDocument/documentSymbol
                `(:textDocument (:uri ,(kargu-lsp--buffer-uri buffer)))
                :timeout (/ timeout-ms 1000.0)
                :success-fn (lambda (raw) (unless delivered (run-at-time 0 nil #'capture raw)))
                :error-fn (lambda (_error) (finish nil 'unavailable)) :timeout-fn (lambda () (finish nil 'timeout))))
              (_ (finish nil 'unavailable))))
        (quit (finish nil 'cancelled))
        (kargu-lsp-coordinate-timeout (finish nil 'timeout))
        (error (finish nil 'unavailable))))))

(defun kargu-lsp-snapshot-body (range)
  "Capture a bounded raw prefix of exact scalar RANGE from this live buffer."
  (save-excursion
    (save-restriction
      (widen)
      (let* ((start (kargu-lsp-coordinate-point (gethash "start" range)))
             (end (kargu-lsp-coordinate-point (gethash "end" range)))
             (cursor start) (bytes 0))
        (unless (<= start end) (error "Reversed body range"))
        (while (and (< cursor end)
                    (<= (+ bytes (string-bytes (encode-coding-string (char-to-string (char-after cursor)) 'utf-8-unix)))
                        kargu-lsp-snapshot--text-bytes))
          (setq bytes (+ bytes (string-bytes (encode-coding-string (char-to-string (char-after cursor)) 'utf-8-unix)))
                cursor (1+ cursor)))
        (kargu-bridge--object "range" range "text" (buffer-substring-no-properties start cursor)
                              "truncated" (if (< cursor end) t :json-false))))))

(provide 'kargu/tools/lsp/snapshot)
;;; snapshot.el ends here
