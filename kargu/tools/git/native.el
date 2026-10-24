;;; native.el --- Native Git read adapter -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Immutable editor input capture; Rust/Git own status execution and reporting.

;;; Code:

(require 'kargu/bridge/read)

(defun kargu-git-native-status (callback root timeout output-bytes)
  "Report native status in ROOT to CALLBACK with TIMEOUT and OUTPUT-BYTES.
TIMEOUT is seconds or nil; no legacy process fallback is executed."
  (unless (or (null timeout) (and (numberp timeout) (> timeout 0)))
    (error "Git timeout must be positive or nil"))
  (kargu-bridge-read-task
   callback
   (kargu-bridge--object "root" (copy-sequence root) "output_bytes" output-bytes
                        "timeout_ms" (if timeout (max 1 (ceiling (* 1000 timeout))) :json-null))
   #'kargu-bridge-git-status))

(provide 'kargu/tools/git/native)
;;; native.el ends here
