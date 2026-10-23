;;; group.el --- Customization namespace -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Define the package's customization group without loading runtime state.

;;; Code:

(defgroup kargu nil
  "Agentic AI development assistant for Emacs."
  :group 'tools
  :prefix "kargu-")

(provide 'kargu/core/group)
;;; group.el ends here
