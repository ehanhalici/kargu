;;; test-native-symbols.el --- Typed live symbol adapter contracts -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Final 3/4/5 acceptance sources.  These exercise scalar coordinates, raw
;; provider capture, frame bounds and exact owner/resource lifetime.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'tests/test-native-session)
(require 'kargu/bridge/sensor/symbols)

(defun kargu-native-symbols-test--range ()
  "Return a two-scalar range containing an emoji and a Greek letter."
  (kargu-bridge--object "start" (kargu-bridge--object "line" 2 "column" 2)
                        "end" (kargu-bridge--object "line" 2 "column" 4)))

(defun kargu-native-symbols-test--tree ()
  "Return raw symbol metadata with no selected body or display text."
  (kargu-bridge--object "symbols" (vector (kargu-bridge--object
                                         "name" "alpha" "kind" "function" "range" (kargu-native-symbols-test--range)
                                         "children" [])) "truncated" :json-false))

(defmacro kargu-native-symbols-test--with-source (tool &rest body)
  "Evaluate BODY with a captured native TOOL and unsaved live source."
  (declare (indent 1) (debug t))
  `(let* ((root (make-temp-file "kargu-symbols-" t))
          (source (generate-new-buffer " *native-symbol-source*"))
          (connection (kargu-bridge--connection-create :state 'ready :epoch "fixture-epoch"))
          (params (kargu-bridge--object
                   "request_id" "forward" "connection_epoch" "fixture-epoch" "scope" (kargu-native-session-test--scope)
                   "root" (directory-file-name root) "call_id" "symbol-call" "tool" ,tool "timeout_ms" 1000
                   "arguments" (kargu-bridge--object "file_path" "source.el" "symbol" "alpha")))
          replies)
     (unwind-protect
         (with-current-buffer source
           (emacs-lisp-mode)
           (setq buffer-file-name (expand-file-name "source.el" root))
           (insert "prefix\n  🦀β suffix\n")
           (let ((entry (kargu-native-session-test--entry connection root source)))
             (puthash "editor_available" (vector ,tool) (kargu-bridge--pending-session-intent entry)))
           (cl-letf (((symbol-function 'kargu-bridge-sensor--reply)
                      (lambda (_connection id value) (push (cons id value) replies)))
                     ((symbol-function 'kargu-lsp-snapshot-capture)
                      (lambda (_buffer _source callback _timeout)
                        (funcall callback (kargu-native-symbols-test--tree) nil))))
             ,@body))
       (when (buffer-live-p source) (with-current-buffer source (set-buffer-modified-p nil)) (kill-buffer source))
       (delete-directory root t))))

(ert-deftest kargu-native-symbols-coordinates-convert-negotiated-units-without-clamping-test ()
  (with-temp-buffer
    (insert "\t🦀β\r\nnext\n")
    (goto-char 3) (narrow-to-region 2 4)
    (let ((point-before (point)) (min-before (point-min)) (max-before (point-max)))
      (dolist (encoding '("utf-8" "utf-16" "utf-32"))
        (let* ((end (pcase encoding ("utf-8" 5) ("utf-16" 3) (_ 2)))
               (range (kargu-lsp-snapshot--range
                       (list :start (list :line 0 :character 1) :end (list :line 0 :character end)) encoding)))
          (should (= (gethash "column" (gethash "start" range)) 1))
          (should (= (gethash "column" (gethash "end" range)) 2))))
      (should-error (kargu-lsp-snapshot--position '(:line 0 :character 2) "utf-16"))
      (should-error (kargu-lsp-snapshot--position '(:line 20 :character 0) "utf-16"))
      (should-error (kargu-lsp-coordinate-point (kargu-bridge--object "line" 1 "column" 4)))
      (should (= (point) point-before)) (should (= (point-min) min-before)) (should (= (point-max) max-before)))))

(ert-deftest kargu-native-symbols-coordinate-work-and-deadline-are-bounded-test ()
  (with-temp-buffer
    (insert "abc\n")
    (let ((kargu-lsp-coordinate--remaining 1))
      (should-error (kargu-lsp--lsp-pos-to-point 0 2 'utf-16) :type 'kargu-lsp-coordinate-limit))
    (let ((kargu-lsp-coordinate--deadline (- (float-time) 1)))
      (should-error (kargu-lsp--lsp-pos-to-point 0 0 'utf-16) :type 'kargu-lsp-coordinate-timeout))
    (let ((kargu-lsp-coordinate--line-remaining 1)
          (kargu-lsp-coordinate--lines (make-hash-table :test #'eql))
          (kargu-lsp-coordinate--cursor (cons 0 (point-min))))
      (should-error (kargu-lsp--lsp-pos-to-point 1 0 'utf-16) :type 'kargu-lsp-coordinate-limit))
    (should (= (kargu-lsp--lsp-pos-to-point 0 2 'utf-16) 3))))

(ert-deftest kargu-native-symbols-imenu-capture-is-raw-and-preserves-live-state-test ()
  (with-temp-buffer
    (emacs-lisp-mode)
    (insert "(defun alpha () nil)\n(defvar β 1)\n")
    (goto-char (point-max)) (narrow-to-region 21 (point-max))
    (let* ((imenu--index-alist '(("stale-menu-entry" . 1)))
           (imenu-auto-rescan nil) (imenu-max-item-length 3)
           (point-before (point)) (min-before (point-min)) (max-before (point-max))
           (tick (buffer-chars-modified-tick))
           (symbols (kargu-lsp-snapshot--imenu-symbols))
           (names (mapcar (lambda (node) (gethash "name" node)) (append (gethash "symbols" symbols) nil))))
      (should (member "alpha" names)) (should (member "β" names))
      (should-not (member "stale-menu-entry" names))
      (should (equal imenu--index-alist '(("stale-menu-entry" . 1))))
      (should (= tick (buffer-chars-modified-tick)))
      (should (= point-before (point))) (should (= min-before (point-min))) (should (= max-before (point-max)))
      (should (stringp (json-serialize symbols :false-object :json-false :null-object :json-null))))))

(ert-deftest kargu-native-symbols-server-process-version-and-encoding-are-captured-test ()
  (with-temp-buffer
    (let ((eglot--managed-mode t) (eglot--versioned-identifier 3)
          (eglot-current-linepos-function #'eglot-utf-16-linepos)
          (server (vector 'server)) (process 'process-1) (flushes 0))
      (cl-letf (((symbol-function 'eglot-current-server) (lambda () server))
                ((symbol-function 'jsonrpc-running-p) (lambda (_server) t))
                ((symbol-function 'jsonrpc--process) (lambda (_server) process))
                ((symbol-function 'eglot-server-capable) (lambda (&rest _) t))
                ((symbol-function 'eglot--signal-textDocument/didChange) (lambda () (cl-incf flushes))))
        (let ((first (kargu-lsp-snapshot-source t)))
          (should (= flushes 1))
          (should (kargu-bridge-sensor--equal-p first (kargu-lsp-snapshot-source)))
          (setq process 'process-2)
          (should-not (equal (gethash "server" first) (gethash "server" (kargu-lsp-snapshot-source))))
          (setq eglot--versioned-identifier 4)
          (should (= (gethash "version" (kargu-lsp-snapshot-source)) 4))
          (setq eglot-current-linepos-function #'ignore)
          (should-error (kargu-lsp-snapshot-source)))))))

(ert-deftest kargu-native-symbols-foreign-body-cannot-consume-the-native-selected-source-test ()
  (kargu-native-symbols-test--with-source "read_symbol"
    (goto-char 10) (narrow-to-region 8 (point-max))
    (let ((point-before (point)) (min-before (point-min)) (max-before (point-max)))
      (kargu-bridge-sensor-prepare-tool connection "capture" params)
      (puthash "resource" (gethash "resource" (cdar replies)) params)
      (should (equal (gethash "kind" (gethash "resource" params)) "language_document"))
      (kargu-bridge-sensor-call-tool connection "symbols" params)
      (should (equal (gethash "kind" (gethash "observation" (cdar replies))) "symbols"))
      (should (eq (kargu-bridge-sensor-call-state (gethash "symbol-call" (kargu-bridge-connection-sensor-calls connection))) :symbols-ready))
      (puthash "range" (kargu-native-symbols-test--range) params)
      (let ((foreign (kargu-bridge-sensor--copy params)))
        (puthash "generation" 2 (gethash "scope" foreign))
        (kargu-bridge-sensor-symbols-body connection "foreign" foreign)
        (should (= (hash-table-count (kargu-bridge-connection-sensor-calls connection)) 1)))
      (kargu-bridge-sensor-symbols-body connection "body" params)
      (let ((snapshot (gethash "snapshot" (gethash "observation" (cdar replies)))))
        (should (equal (gethash "text" snapshot) "🦀β"))
        (should (eq (gethash "truncated" snapshot) :json-false)))
      (should (= (hash-table-count (kargu-bridge-connection-sensor-calls connection)) 0))
      (should-not (file-exists-p buffer-file-name))
      (should (= point-before (point))) (should (= min-before (point-min))) (should (= max-before (point-max))))))

(ert-deftest kargu-native-symbols-truncation-is-explicit-and-never-closes-the-connection-test ()
  (kargu-native-symbols-test--with-source "read_file_symbols"
    (setf (kargu-bridge-connection-frame-limit connection) 1024)
    (let* ((snapshot (kargu-bridge--object
                      "requested" (kargu-bridge--object "path" "source.el" "document_id" "doc" "tick" 1)
                      "observed" (kargu-bridge--object "path" "source.el" "document_id" "doc" "tick" 1)
                      "source" (kargu-bridge--object "kind" "imenu" "provider" "imenu")
                      "observed_source" (kargu-bridge--object "kind" "imenu" "provider" "imenu")
                      "symbols" (kargu-bridge--object
                                   "symbols" (vconcat (cl-loop repeat 60 collect
                                                              (kargu-bridge--object "name" (make-string 100 ?x) "kind" "function"
                                                                                    "range" (kargu-native-symbols-test--range) "children" [])))
                                   "truncated" :json-false)))
           (result (kargu-bridge--object "scope" (gethash "scope" params) "call_id" "symbol-call" "quiescent" t "outcome" "ok"
                                        "observation" (kargu-bridge--object "kind" "symbols" "snapshot" snapshot))))
      (kargu-bridge-sensor-symbols--fit connection "bounded" result)
      (should (eq (kargu-bridge-status connection) 'ready))
      (should (<= (kargu-bridge-sensor-symbols--size (kargu-bridge--object "jsonrpc" "2.0" "id" "bounded" "result" result)) 1024))
      (when (equal (gethash "outcome" result) "ok")
        (should (eq (gethash "truncated" (gethash "symbols" snapshot)) t))))))

(ert-deftest kargu-native-symbols-source-change-and-foreign-release-preserve-correlation-test ()
  (kargu-native-symbols-test--with-source "read_symbol"
    (kargu-bridge-sensor-prepare-tool connection "capture" params)
    (puthash "resource" (gethash "resource" (cdar replies)) params)
    (kargu-bridge-sensor-call-tool connection "symbols" params)
    (let ((foreign (kargu-bridge-sensor--copy params)))
      (puthash "generation" 2 (gethash "scope" foreign))
      (kargu-bridge-sensor-symbols-release connection foreign)
      (should (= (hash-table-count (kargu-bridge-connection-sensor-calls connection)) 1)))
    (puthash "range" (kargu-native-symbols-test--range) params)
    (insert "source changed")
    (kargu-bridge-sensor-symbols-body connection "body" params)
    (should (equal (gethash "outcome" (cdar replies)) "rejected"))
    (should (= (hash-table-count (kargu-bridge-connection-sensor-calls connection)) 0))))

(ert-deftest kargu-native-symbols-foreign-root-is-refused-before-provider-flush-test ()
  (let ((root (make-temp-file "kargu-symbol-root-" t)) flushed)
    (unwind-protect
        (with-temp-buffer
          (setq buffer-file-name (expand-file-name "../foreign.el" root))
          (cl-letf (((symbol-function 'kargu-lsp-snapshot-source)
                     (lambda (&optional _flush) (setq flushed t) (kargu-bridge--object "kind" "imenu" "provider" "foreign"))))
            (should-error (kargu-bridge-sensor--language-document (current-buffer) root t))
            (should-not flushed)))
      (delete-directory root t))))

(ert-deftest kargu-native-symbols-imenu-does-not-follow-a-foreign-marker-test ()
  (let ((foreign (generate-new-buffer " *foreign-imenu-document*")) marker)
    (unwind-protect
        (with-temp-buffer
          (emacs-lisp-mode) (insert "(defun alpha () nil)\n")
          (with-current-buffer foreign (insert "(defun secret () nil)\n") (setq marker (copy-marker (point-min))))
          (let ((imenu-create-index-function (lambda () (list (cons "secret" marker)))))
            (should-error (kargu-lsp-snapshot--imenu-symbols))))
      (when marker (set-marker marker nil))
      (when (buffer-live-p foreign) (kill-buffer foreign)))))

(ert-deftest kargu-native-symbols-actual-rpc-timeout-survives-elisp-owner-replacement-test ()
  (with-temp-buffer
    (let ((kargu--loop-run (list :old-run t)) success timeout replies)
      (cl-letf (((symbol-function 'eglot-current-server) (lambda () 'fixture-server))
                ((symbol-function 'kargu-lsp--buffer-uri) (lambda (_buffer) "file:///fixture.el"))
                ((symbol-function 'jsonrpc-async-request)
                 (lambda (_server _method _params &rest options)
                   (should (= (plist-get options :timeout) 1.0))
                   (setq success (plist-get options :success-fn) timeout (plist-get options :timeout-fn)))))
        (kargu-lsp-snapshot-capture
         (current-buffer) (kargu-bridge--object "kind" "eglot" "server" "fixture-server" "version" 1 "encoding" "utf-16")
         (lambda (value failure) (push (list value failure) replies)) 1000)
        (setq kargu--loop-run (list :new-run t))
        (funcall timeout)
        (should (equal replies '((nil timeout))))
        (cl-letf (((symbol-function 'kargu-lsp-snapshot--symbols)
                   (lambda (&rest _) (ert-fail "Late symbol reply performed another capture"))))
          (funcall success []))
        (should (= (length replies) 1))))))

(provide 'tests/test-native-symbols)
;;; test-native-symbols.el ends here
