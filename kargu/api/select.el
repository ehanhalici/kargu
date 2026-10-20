;;; select.el --- Compatibility entry for selection UI -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Preserve the old feature name without making the API load the UI.

;;; Code:

(require 'kargu/chat/select)

(provide 'kargu/api/select)
;;; select.el ends here
