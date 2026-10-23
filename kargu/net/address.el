;;; address.el --- Numeric IP parsing and public-address policy -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Pure parsing: no DNS lookup or platform-specific binary is used.
;; The conservative fetch policy follows the IANA special-purpose registries:
;; https://www.iana.org/assignments/iana-ipv4-special-registry/
;; https://www.iana.org/assignments/iana-ipv6-special-registry/
;; Known NAT64 embedding is defined in RFC 6052.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'seq)
(require 'rx)

(defun kargu-ip--v4 (text)
  "Parse canonical decimal IPv4 TEXT to four bytes, or nil."
  (let ((parts (split-string text "\\." nil)))
    (when (and (= (length parts) 4)
               (cl-every (lambda (part)
                           (and (string-match-p
                                 (rx bos (or "0" (seq (any "1-9") (** 0 2 (any "0-9")))) eos) part)
                                (<= (string-to-number part) 255))) parts))
      (vconcat (mapcar #'string-to-number parts)))))

(defun kargu-ip--hex-groups (text)
  "Parse IPv6 hex groups in TEXT, returning :invalid on malformed input."
  (if (string-empty-p text) nil
    (let ((parts (split-string text ":" nil)))
      (if (cl-every (lambda (part)
                     (string-match-p (rx bos (** 1 4 (any "0-9a-fA-F")) eos) part)) parts)
          (mapcar (lambda (part) (string-to-number part 16)) parts)
        :invalid))))

(defun kargu-ip--expand-dotted-tail (text)
  "Replace an IPv4 tail in IPv6 TEXT with hex groups, or return nil."
  (if (not (string-search "." text)) text
    (when-let* ((colon (cl-position ?: text :from-end t))
                (address (kargu-ip--v4 (substring text (1+ colon)))))
      (concat (substring text 0 (1+ colon))
              (format "%x:%x" (+ (ash (aref address 0) 8) (aref address 1))
                      (+ (ash (aref address 2) 8) (aref address 3)))))))

(defun kargu-ip--v6-groups (text)
  "Expand valid IPv6 TEXT into exactly eight groups, or return nil."
  (let ((compression (string-search "::" text)))
    (if (not compression)
        (let ((groups (kargu-ip--hex-groups text)))
          (and (listp groups) (= (length groups) 8) groups))
      (unless (string-search "::" text (+ compression 2))
        (let ((left (kargu-ip--hex-groups (substring text 0 compression)))
              (right (kargu-ip--hex-groups (substring text (+ compression 2)))))
          (when (and (listp left) (listp right) (< (+ (length left) (length right)) 8))
            (append left (make-list (- 8 (length left) (length right)) 0) right)))))))

(defun kargu-ip-address (text)
  "Parse bare numeric IP TEXT into four or sixteen bytes, or return nil.
Reject zone IDs, ambiguous IPv4 notation and malformed IPv6 compression.
This function never resolves names and preserves the caller's match data."
  (save-match-data
    (when (and (stringp text) (<= (length text) 45))
      (if (not (string-search ":" text)) (kargu-ip--v4 text)
        (when-let* ((expanded (kargu-ip--expand-dotted-tail text))
                    (groups (kargu-ip--v6-groups expanded)))
          (vconcat (cl-loop for group in groups
                            append (list (ash group -8) (logand group 255)))))))))

(defun kargu-ip--prefix-p (address prefix bits)
  "Return non-nil if byte vector ADDRESS matches PREFIX for BITS bits."
  (let* ((whole (/ bits 8)) (remaining (% bits 8))
         (mask (logand 255 (ash 255 (- 8 remaining)))))
    (and (= (length address) (length prefix))
         (cl-loop for index below whole always (= (aref address index) (aref prefix index)))
         (or (zerop remaining)
             (= (logand (aref address whole) mask) (logand (aref prefix whole) mask))))))

(defconst kargu-ip--denied-v4
  (mapcar (lambda (entry) (cons (kargu-ip-address (car entry)) (cdr entry)))
          '(("0.0.0.0" . 8) ("10.0.0.0" . 8) ("100.64.0.0" . 10)
            ("127.0.0.0" . 8) ("169.254.0.0" . 16) ("172.16.0.0" . 12)
            ("192.0.0.0" . 24) ("192.0.2.0" . 24) ("192.88.99.0" . 24)
            ("192.168.0.0" . 16) ("198.18.0.0" . 15) ("198.51.100.0" . 24)
            ("203.0.113.0" . 24) ("224.0.0.0" . 3)))
  "Conservatively excluded private and special-purpose IPv4 networks.")

(defconst kargu-ip--denied-v6
  (mapcar (lambda (entry) (cons (kargu-ip-address (car entry)) (cdr entry)))
          '(("2001::" . 23) ("2001:db8::" . 32) ("2002::" . 16) ("3fff::" . 20)))
  "Special-purpose IPv6 ranges excluded inside global unicast space.
The whole IETF-assignment range and transition ranges are conservatively
excluded, including their more-specific exceptions.")

(defconst kargu-ip--mapped-prefix (kargu-ip-address "::ffff:0:0")
  "IPv4-mapped IPv6 prefix, compared for its first 96 bits.")

(defconst kargu-ip--nat64-prefix (kargu-ip-address "64:ff9b::")
  "Well-known NAT64 prefix, compared for its first 96 bits.")

(defconst kargu-ip--unicast-prefix (kargu-ip-address "2000::")
  "Global unicast prefix, compared for its first three bits.")

(defun kargu-ip-public-p (address)
  "Return non-nil if numeric ADDRESS passes the conservative fetch policy.
Mapped IPv4 and well-known NAT64 addresses inherit their IPv4 policy.
Other non-global ranges, scoped addresses and special-purpose ranges fail."
  (and (vectorp address) (memq (length address) '(4 16))
       (cl-every (lambda (byte) (and (integerp byte) (<= 0 byte 255))) address)
       (pcase (length address)
         (4 (not (seq-some (lambda (entry) (kargu-ip--prefix-p address (car entry) (cdr entry)))
                           kargu-ip--denied-v4)))
         (16 (if (or (kargu-ip--prefix-p address kargu-ip--mapped-prefix 96)
                     (kargu-ip--prefix-p address kargu-ip--nat64-prefix 96))
                 (kargu-ip-public-p (cl-subseq address 12))
               (and (kargu-ip--prefix-p address kargu-ip--unicast-prefix 3)
                    (not (seq-some
                          (lambda (entry) (kargu-ip--prefix-p address (car entry) (cdr entry)))
                          kargu-ip--denied-v6))))))))

(defun kargu-ip-format (address)
  "Format parsed ADDRESS as an unambiguous numeric address string."
  (pcase (length address)
    (4 (mapconcat #'number-to-string address "."))
    (16 (mapconcat (lambda (index)
                     (format "%x" (+ (ash (aref address index) 8) (aref address (1+ index)))))
                   '(0 2 4 6 8 10 12 14) ":"))
    (_ (error "Not a parsed IP address"))))

(provide 'kargu/net/address)
;;; address.el ends here
