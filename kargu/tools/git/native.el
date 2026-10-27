;;; native.el --- Native Git read adapter -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Immutable editor input capture; Rust/Git own status execution and reporting.

;;; Code:

(require 'kargu/bridge/read)
(require 'kargu/bridge/command)

(defun kargu-git-native-mutate (callback root timeout output-bytes query)
  "Approve closed native QUERY in ROOT into CALLBACK with TIMEOUT/OUTPUT-BYTES."
  (let* ((capture (kargu-bridge-command-capture "git" nil root :timeout timeout :output-bytes output-bytes))
         (arguments (kargu-bridge-command-arguments capture)))
    (dolist (key '("program" "arguments" "cwd" "idle_timeout_ms" "stderr")) (remhash key arguments))
    (puthash "query" query arguments)
    (kargu-bridge-read-task
     callback arguments
     (lambda (connection args done &rest options)
       (kargu-bridge-approval-execute connection args done :owner (plist-get options :owner)
                                      :method "git/mutate" :capability "git_mutation"
                                      :valid-p (kargu-bridge-command-valid-p capture))))))

(defun kargu-git-native-read (callback root timeout output-bytes query)
  "Run closed native QUERY in ROOT into CALLBACK.
Capture TIMEOUT and OUTPUT-BYTES; Git policy and argv belong to Rust."
  (unless (or (null timeout) (and (numberp timeout) (> timeout 0)))
    (error "Git timeout must be positive or nil"))
  (kargu-bridge-read-task
   callback
   (kargu-bridge--object "root" (copy-sequence root) "output_bytes" output-bytes
                         "timeout_ms" (if timeout (max 1 (ceiling (* 1000 timeout))) :json-null)
                         "query" query)
   #'kargu-bridge-git-read))

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
