;;; test-native-file.el --- Native parent-run live-file capture contracts -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Final-gate acceptance sources for RAM/disk-source observation and recheck.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'kargu/bridge/file)
(require 'tests/test-native-session)

(defun kargu-native-file-test--params (root)
  "Create one exact native read_file capture under ROOT."
  (kargu-bridge--object "request_id" "forward" "connection_epoch" "fixture-epoch"
                       "scope" (kargu-native-session-test--scope)
                       "root" (directory-file-name (file-truename root))
                       "call_id" "call_12345678-1234-4234-8234-000000000005" "tool" "read_file"
                       "arguments" (kargu-bridge--object "file_path" "source.rs" "from_line" 2)
                       "capture" (kargu-bridge--object "path" "source.rs" "from" 2
                                                       "to" :json-null "scan_chars" 4096 "output_chars" 2000)))

(defun kargu-native-file-test--validate (params reply)
  "Detach a validation request from capture PARAMS and REPLY."
  (let ((params (kargu-bridge-sensor--copy params))
        (stamp (kargu-bridge-sensor--copy (gethash "observation" reply))))
    (remhash "source" stamp)
    (remhash "capture" params)
    (puthash "observation" stamp params)
    params))

(ert-deftest kargu-native-file-capture-preserves-unsaved-text-narrowing-point-and-stamp-test ()
  (let* ((root (make-temp-file "kargu-native-ram-" t))
         (buffer (generate-new-buffer " *native-ram-source*"))
         (connection (kargu-bridge--connection-create :state 'ready :epoch "fixture-epoch"))
         (params (kargu-native-file-test--params root))
         replies)
    (unwind-protect
        (with-current-buffer buffer
          (setq buffer-file-name (expand-file-name "source.rs" root))
          (insert "first\nUNSAVED 🦀\nthird\n")
          (goto-char (point-min)) (forward-line 2)
          (narrow-to-region (point) (point-max))
          (let ((before-point (point)) (before-min (point-min)) (before-max (point-max))
                (tick (buffer-chars-modified-tick)))
            (kargu-native-session-test--entry connection (gethash "root" params) buffer)
            (cl-letf (((symbol-function 'kargu-bridge-sensor--reply)
                       (lambda (_connection id value) (push (cons id value) replies))))
              (kargu-bridge-file-capture connection "capture" params)
              (let* ((captured (cdar replies))
                     (observation (gethash "observation" captured))
                     (source (gethash "source" observation)))
                (should (equal (gethash "kind" observation) "editor"))
                (should (string-prefix-p "UNSAVED 🦀" (gethash "text" source)))
                (should (= (gethash "tick" (gethash "document" observation)) tick))
                (should (eq (gethash "dirty" observation) t))
                (should (= before-point (point)))
                (should (= before-min (point-min)))
                (should (= before-max (point-max)))
                (should (buffer-modified-p))
                (should-not (file-exists-p buffer-file-name))
                (kargu-bridge-file-validate connection "validation"
                                             (kargu-native-file-test--validate params captured))
                (should (eq (gethash "current" (cdar replies)) t))
                (should (= (hash-table-count (kargu-bridge-connection-file-observations connection)) 0))
                (should (= (hash-table-count (kargu-bridge-connection-reverse-cleanups connection)) 0))))))
      (when (buffer-live-p buffer) (with-current-buffer buffer (set-buffer-modified-p nil)) (kill-buffer buffer))
      (delete-directory root t))))

(ert-deftest kargu-native-file-foreign-validation-cannot-consume-a-captured-document-test ()
  (let* ((root (make-temp-file "kargu-native-foreign-" t))
         (buffer (generate-new-buffer " *native-owned-source*"))
         (connection (kargu-bridge--connection-create :state 'ready :epoch "fixture-epoch"))
         (params (kargu-native-file-test--params root))
         replies)
    (unwind-protect
        (with-current-buffer buffer
          (setq buffer-file-name (expand-file-name "source.rs" root))
          (insert "first\nsecond\n")
          (kargu-native-session-test--entry connection (gethash "root" params) buffer)
          (cl-letf (((symbol-function 'kargu-bridge-sensor--reply)
                     (lambda (_connection id value) (push (cons id value) replies))))
            (kargu-bridge-file-capture connection "capture" params)
            (let* ((valid (kargu-native-file-test--validate params (cdar replies)))
                   (foreign (kargu-bridge-sensor--copy valid)))
              (puthash "generation" 2 (gethash "scope" foreign))
              (kargu-bridge-file-validate connection "foreign" foreign)
              (should (eq (gethash "current" (cdar replies)) :json-false))
              (should (= (hash-table-count (kargu-bridge-connection-file-observations connection)) 1))
              (goto-char (point-max)) (insert "new edit\n")
              (kargu-bridge-file-validate connection "legitimate" valid)
              (should (eq (gethash "current" (cdar replies)) :json-false))
              (should (= (hash-table-count (kargu-bridge-connection-file-observations connection)) 0)))))
      (when (buffer-live-p buffer) (with-current-buffer buffer (set-buffer-modified-p nil)) (kill-buffer buffer))
      (delete-directory root t))))

(ert-deftest kargu-native-file-new-buffer-invalidates-an-observed-disk-source-test ()
  (let* ((root (make-temp-file "kargu-native-new-buffer-" t))
         (owner (generate-new-buffer " *native-file-origin*"))
         (source (generate-new-buffer " *native-new-source*"))
         (connection (kargu-bridge--connection-create :state 'ready :epoch "fixture-epoch"))
         (params (kargu-native-file-test--params root))
         replies)
    (unwind-protect
        (progn
          (kargu-native-session-test--entry connection (gethash "root" params) owner)
          (cl-letf (((symbol-function 'kargu-bridge-sensor--reply)
                     (lambda (_connection id value) (push (cons id value) replies))))
            (kargu-bridge-file-capture connection "capture" params)
            (let ((validation (kargu-native-file-test--validate params (cdar replies))))
              (should (equal (gethash "kind" (gethash "observation" (cdar replies))) "disk"))
              (with-current-buffer source
                (setq buffer-file-name (expand-file-name "source.rs" root))
                (insert "unsaved replacement\n"))
              (kargu-bridge-file-validate connection "validation" validation)
              (should (eq (gethash "current" (cdar replies)) :json-false))
              (should (= (hash-table-count (kargu-bridge-connection-file-observations connection)) 0)))))
      (dolist (buffer (list owner source))
        (when (buffer-live-p buffer) (with-current-buffer buffer (set-buffer-modified-p nil)) (kill-buffer buffer)))
      (delete-directory root t))))

(ert-deftest kargu-native-file-oversized-probe-refuses-without-closing-the-connection-test ()
  (let* ((root (make-temp-file "kargu-native-frame-" t))
         (buffer (generate-new-buffer " *native-large-source*"))
         (connection (kargu-bridge--connection-create :state 'ready :epoch "fixture-epoch" :frame-limit 1024))
         (params (kargu-native-file-test--params root))
         failed)
    (unwind-protect
        (with-current-buffer buffer
          (setq buffer-file-name (expand-file-name "source.rs" root))
          (insert (make-string 4096 ?🦀))
          (kargu-native-session-test--entry connection (gethash "root" params) buffer)
          (cl-letf (((symbol-function 'kargu-bridge-sensor--error)
                     (lambda (_connection _id) (setq failed t))))
            (kargu-bridge-file-capture connection "capture" params)
            (should failed)
            (should (eq (kargu-bridge-status connection) 'ready))
            (should (= (hash-table-count (kargu-bridge-connection-file-observations connection)) 0))
            (should (= (hash-table-count (kargu-bridge-connection-reverse-cleanups connection)) 0))))
      (when (buffer-live-p buffer) (with-current-buffer buffer (set-buffer-modified-p nil)) (kill-buffer buffer))
      (delete-directory root t))))

(provide 'tests/test-native-file)
;;; test-native-file.el ends here
