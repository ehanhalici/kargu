;;; kargu/providers/stepfun.el --- StepFun provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for StepFun (stepfun).

;;; Code:

(eval-and-compile
  (let ((root (locate-dominating-file
               (or (bound-and-true-p byte-compile-current-file)
                   load-file-name
                   buffer-file-name
                   default-directory)
               "kargu.el")))
    (when root
      (add-to-list 'load-path (file-name-as-directory
                               (expand-file-name root))))))

(require 'kargu/providers/registry)

(kargu-register-provider
 :id "stepfun"
 :name "StepFun"
 :api "https://api.stepfun.com/v1"
 :env '("STEPFUN_API_KEY")
 :models '("step-1-32k" "step-3.7-flash" "step-3.5-flash-2603" "stepaudio-2.5-tts" "stepaudio-2.5-asr" "step-3.5-flash" "step-tts-2" "step-2-16k")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/stepfun)

;;; stepfun.el ends here
