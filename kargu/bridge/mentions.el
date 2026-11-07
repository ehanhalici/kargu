;;; mentions.el --- Bounded native mention parsing -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Transfer an immutable source to the native lexer and assemble exact pages.
;; Spans are UTF-8 byte coordinates, never file-access or egress permissions.

;;; Code:

(require 'kargu/bridge)
(require 'kargu/async)

(cl-defun kargu-bridge-mentions-parse (source callback &key parent valid-p)
  "Parse immutable SOURCE into CALLBACK (SPANS FAILURE) under PARENT.
VALID-P guards the caller's input snapshot.  Spans retain native byte offsets.
No partial page set is delivered, and this function does not read target files."
  (let* ((source (copy-sequence source))
         (bytes (string-bytes source))
         (hash (secure-hash 'sha256 (encode-coding-string source 'utf-8 t)))
         (task (kargu-async-start callback :parent parent :valid-p valid-p :owner nil))
         (offset 0) total spans connection epoch)
    (cl-labels
        ((fail () (kargu-async-finish task nil "Native mention parsing unavailable"))
         (page ()
           (when (kargu-async-pending-p task)
             (let ((id (kargu-bridge-call
                        connection "mentions/parse"
                        (kargu-bridge--object "connection_epoch" epoch "source" source "offset" offset)
                        (kargu-async-wrap task #'received))))
               (when id
                 (kargu-async-add-cleanup task (lambda () (kargu-bridge-cancel connection id)))))))
         (received (result failure)
           (if (or failure (not (hash-table-p result)))
               (fail)
             (let ((next (gethash "next_offset" result))
                   (count (gethash "total" result))
                   (entries (gethash "spans" result))
                   (done (gethash "done" result)))
               (if (not (and (equal hash (gethash "source_hash" result))
                             (equal bytes (gethash "source_bytes" result))
                             (equal "utf8_bytes" (gethash "coordinates" result))
                             (equal offset (gethash "offset" result))
                             (natnump next) (natnump count) (<= count 256)
                             (or (null total) (= total count))
                             (vectorp entries) (= next (+ offset (length entries)))
                             (<= next count) (memq done '(t :json-false))
                             (eq (eq done t) (= next count))
                             (or (eq done t) (> next offset))))
                   (fail)
                 (setq total count offset next spans (append spans (append entries nil)))
                 (if (eq done t)
                     (kargu-async-finish task (vconcat spans))
                   (page)))))))
      (when (kargu-async-pending-p task)
        (kargu-async-add-cleanup
         task (kargu-bridge-ensure
               (kargu-async-wrap
                task (lambda (ready failure)
                       (if failure (fail)
                         (setq connection ready epoch (kargu-bridge-connection-epoch ready))
                         (page))))))))
    task))

(provide 'kargu/bridge/mentions)
;;; mentions.el ends here
