;;; test-mentions-port.el --- Native mention DTO transfer -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; No target content is read.  Paging stays tied to one immutable UTF-8 source.

;;; Code:

(require 'ert)
(require 'tests/test-helpers)
(require 'tests/test-bridge)
(require 'kargu/bridge/mentions)

(ert-deftest kargu-mentions-port-real-minimum-frame-pages-test ()
  "Real native pages assemble without changing the minimum frame limit."
  (let ((kargu-bridge--max-frame 1024))
    (kargu-bridge-test--with-core
     (let ((source (concat "🦀 " (mapconcat (lambda (n) (format "@f%d.rs" n)) (number-sequence 0 59) " ")))
           spans failure done)
       (kargu-bridge-mentions-parse source (lambda (value error-data)
                                           (setq spans value failure error-data done t)))
       (kargu-bridge-test--wait (lambda () done))
       (should-not failure)
       (should (= (length spans) 60))
       (should (= (gethash "start" (aref spans 0)) 5))
       (should (equal (gethash "raw" (aref spans 59)) "@f59.rs"))))))

(ert-deftest kargu-mentions-port-wrong-source-page-never-delivers-a-prefix-test ()
  "A later foreign source hash discards all accumulated spans."
  (let (callback result failure done (calls 0))
    (cl-letf (((symbol-function 'kargu-bridge-ensure)
               (lambda (ready) (funcall ready (kargu-bridge--connection-create :epoch "epoch") nil) #'ignore))
              ((symbol-function 'kargu-bridge-call)
               (lambda (_conn _method _params received &rest _)
                 (cl-incf calls) (setq callback received) nil)))
      (kargu-bridge-mentions-parse "@a.rs @b.rs"
                                  (lambda (value error-data) (setq result value failure error-data done t)))
      (funcall callback (kargu-bridge--object
                         "source_hash" (secure-hash 'sha256 "@a.rs @b.rs") "source_bytes" 11
                         "coordinates" "utf8_bytes" "offset" 0 "next_offset" 1 "total" 2
                         "spans" (vector (kargu-bridge--object "raw" "@a.rs")) "done" :json-false) nil)
      (should (= calls 2))
      (should-not done)
      (funcall callback (kargu-bridge--object
                         "source_hash" "foreign" "source_bytes" 11 "coordinates" "utf8_bytes"
                         "offset" 1 "next_offset" 2 "total" 2
                         "spans" (vector (kargu-bridge--object "raw" "@b.rs")) "done" t) nil)
      (should done) (should failure) (should-not result))))

(ert-deftest kargu-mentions-port-cancel-revokes-late-page-test ()
  "Cancelled page callbacks cannot complete the caller's replaced input."
  (let (received delivered cancelled)
    (cl-letf (((symbol-function 'kargu-bridge-ensure)
               (lambda (ready) (funcall ready (kargu-bridge--connection-create :epoch "epoch") nil) #'ignore))
              ((symbol-function 'kargu-bridge-call)
               (lambda (_conn _method _params callback &rest _) (setq received callback) "parse-id"))
              ((symbol-function 'kargu-bridge-cancel)
               (lambda (_conn id) (setq cancelled id))))
      (let ((task (kargu-bridge-mentions-parse "@a.rs" (lambda (&rest _) (setq delivered t)))))
        (kargu-async-cancel task)
        (should (equal cancelled "parse-id"))
        (funcall received nil nil)
        (should-not delivered)))))

(provide 'tests/test-mentions-port)
;;; test-mentions-port.el ends here
