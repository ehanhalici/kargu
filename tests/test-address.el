;;; test-address.el --- Numeric IP policy tests -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Address parsing is pure and never starts a resolver or network request.

;;; Code:

(require 'ert)
(require 'kargu/net/address)

(ert-deftest kargu-ip-refuses-private-and-special-use-equivalents-test ()
  "Expanded, mapped and well-known NAT64 addresses inherit numeric policy."
  (dolist (text '("0.0.0.0" "127.0.0.1" "10.2.3.4" "100.127.255.255"
                  "169.254.1.1" "172.31.255.255" "192.168.1.1" "198.19.0.1"
                  "224.0.0.1" "255.255.255.255" "192.0.2.1" "198.51.100.1"
                  "203.0.113.1" "::" "::1" "0:0:0:0:0:0:0:1"
                  "fe80::1" "fe90::1" "febf::1" "fec0::1" "fc00::1" "fdff::1"
                  "::ffff:127.0.0.1" "0:0:0:0:0:ffff:7f00:1"
                  "64:ff9b::127.0.0.1" "64:ff9b::a00:1" "64:ff9b:1::808:808"
                  "ff02::1" "2001:db8::1" "3fff:0::1" "2002:7f00:1::1"))
    (should (kargu-ip-address text))
    (should-not (kargu-ip-public-p (kargu-ip-address text)))))

(ert-deftest kargu-ip-public-addresses-round-trip-test ()
  "Allowed addresses retain their numeric identity in canonical output."
  (dolist (text '("8.8.8.8" "93.184.216.34" "100.128.0.1" "172.32.0.1"
                  "2606:4700:4700::1111" "2001:4860:4860::8888"
                  "::ffff:8.8.8.8" "64:ff9b::8.8.8.8"))
    (let ((address (kargu-ip-address text)))
      (should (kargu-ip-public-p address))
      (should (equal (kargu-ip-address (kargu-ip-format address)) address)))))

(ert-deftest kargu-ip-malformed-addresses-never-become-names-test ()
  "Malformed, scoped and ambiguous numeric representations fail closed."
  (dolist (text '("example.com" "127.1" "0177.0.0.1" "1.2.3.256" "1.2.3.-1"
                  "::1%lo" "fe80::1%25eth0" ":::1" "1:::" "1::2::3"
                  "1:2:3:4:5:6:7" "1:2:3:4:5:6:7:8:9" "::ffff:127.00.0.1"
                  "[::1]" "::gggg" "::10000"))
    (should-not (kargu-ip-address text)))
  (string-match "keep" "keep")
  (let ((saved (match-data)))
    (kargu-ip-address "2606:4700::1111")
    (should (equal (match-data) saved))))

(ert-deftest kargu-ip-cidr-mask-matches-integer-prefixes-test ()
  "Every IPv4 prefix length agrees with an independent whole-integer check."
  (dolist (pair '(("8.8.8.8" . "224.0.0.0") ("100.127.255.255" . "100.64.0.0")
                  ("100.128.0.0" . "100.64.0.0") ("172.20.0.1" . "172.16.0.0")
                  ("255.255.255.255" . "255.255.255.254")))
    (let* ((address (kargu-ip-address (car pair))) (prefix (kargu-ip-address (cdr pair)))
           (left (cl-reduce (lambda (sum byte) (+ (* sum 256) byte)) address :initial-value 0))
           (right (cl-reduce (lambda (sum byte) (+ (* sum 256) byte)) prefix :initial-value 0)))
      (dotimes (bits 33)
        (should (eq (and (kargu-ip--prefix-p address prefix bits) t)
                    (zerop (ash (logxor left right) (- bits 32)))))))))

(provide 'tests/test-address)
;;; test-address.el ends here
