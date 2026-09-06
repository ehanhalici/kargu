;;; kargu/providers/stepfun-ai.el --- StepFun AI provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for StepFun AI (stepfun-ai).

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
 :id "stepfun-ai"
 :name "StepFun AI"
 :api "https://api.stepfun.ai/step_plan/v1"
 :env '("STEPFUN_API_KEY")
 :models '("step-2-16k" "step-tts-2" "step-3.5-flash" "stepaudio-2.5-asr" "stepaudio-2.5-tts" "step-3.5-flash-2603" "step-3.7-flash" "step-1-32k")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/stepfun-ai)

;;; stepfun-ai.el ends here
