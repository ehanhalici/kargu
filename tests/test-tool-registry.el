;;; test-tool-registry.el --- Explicit tool registry contracts -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Registries are explicit services, not an implicit application singleton.

;;; Code:

(require 'ert)
(require 'kargu/tools/registry)

(ert-deftest kargu-tool-registry-instances-are-isolated-test ()
  "Registering the same name in two services keeps their definitions apart."
  (let ((first (kargu-tool-registry-create))
        (second (kargu-tool-registry-create)))
    (kargu-tool-registry-register first :name "read" :description "First"
                                  :executor #'ignore)
    (kargu-tool-registry-register second :name "read" :description "Second"
                                  :executor #'ignore)
    (should (= (kargu-tool-registry-count first) 1))
    (should (= (kargu-tool-registry-count second) 1))
    (should (equal (kargu-tool-definition-description
                    (kargu-tool-registry-find first "read")) "First"))
    (should (equal (kargu-tool-definition-description
                    (kargu-tool-registry-find second "read")) "Second"))))

(ert-deftest kargu-tool-registry-replacement-preserves-aliases-test ()
  "Aliases resolve the current definition, including aliases of aliases."
  (let ((registry (kargu-tool-registry-create)))
    (kargu-tool-registry-register registry :name "read" :description "Old"
                                  :executor #'ignore)
    (kargu-tool-registry-alias registry "r" "read")
    (kargu-tool-registry-alias registry "rr" "r")
    (kargu-tool-registry-register registry :name "read" :description "New"
                                  :executor #'ignore)
    (should (equal (kargu-tool-registry-canonical-name registry "rr") "read"))
    (should (eq (kargu-tool-registry-find registry "rr")
                (kargu-tool-registry-find registry "read")))
    (should (equal (kargu-tool-definition-description
                    (kargu-tool-registry-find registry "r")) "New"))))

(ert-deftest kargu-tool-registry-policy-is-shared-by-aliases-test ()
  "Changing policy through an alias updates only its canonical tool."
  (let ((registry (kargu-tool-registry-create)))
    (kargu-tool-registry-register registry :name "read" :description "Read"
                                  :executor #'ignore)
    (kargu-tool-registry-alias registry "r" "read")
    (kargu-tool-registry-set-policy registry "r" '(:modes (plan)))
    (should (equal (kargu-tool-definition-policy
                    (kargu-tool-registry-find registry "read"))
                   '(:modes (plan))))))

(ert-deftest kargu-tool-registry-unregister-removes-only-owned-aliases-test ()
  "Removing a canonical tool removes its aliases but not unrelated tools."
  (let ((registry (kargu-tool-registry-create)))
    (dolist (name '("read" "write"))
      (kargu-tool-registry-register registry :name name :description name
                                    :executor #'ignore))
    (kargu-tool-registry-alias registry "r" "read")
    (kargu-tool-registry-alias registry "rr" "r")
    (kargu-tool-registry-alias registry "w" "write")
    (should (kargu-tool-registry-remove registry "read"))
    (should-not (kargu-tool-registry-remove registry "read"))
    (should (equal (sort (kargu-tool-registry-names registry) #'string<)
                   '("w" "write")))))

(ert-deftest kargu-tool-registry-unregister-alias-keeps-tool-test ()
  "Removing an alias leaves its canonical definition and other aliases."
  (let ((registry (kargu-tool-registry-create)))
    (kargu-tool-registry-register registry :name "read" :description "Read"
                                  :executor #'ignore)
    (kargu-tool-registry-alias registry "r" "read")
    (kargu-tool-registry-alias registry "rr" "r")
    (should (kargu-tool-registry-remove registry "r"))
    (should (kargu-tool-registry-find registry "read"))
    (should (kargu-tool-registry-find registry "rr"))))

(ert-deftest kargu-tool-registry-rejects-invalid-input-without-mutation-test ()
  "Invalid definitions cannot overwrite a valid registered tool."
  (let ((registry (kargu-tool-registry-create)))
    (kargu-tool-registry-register registry :name "read" :description "Read"
                                  :executor #'ignore)
    (dolist (arguments '((:name "" :description "Bad" :executor ignore)
                         (:name "read" :description 1 :executor ignore)
                         (:name "read" :description "Bad" :executor 1)
                         (:name "read" :description "Bad" :executor ignore
                          :parameters (("type" . "string")))
                         (:name "read" :description "Bad" :executor ignore
                          :policy (:modes (unknown)))
                         (:name "read" :description "Bad" :executor ignore
                          :policy (:available-p 1))
                         (:name "read" :description "Bad" :executor ignore
                          :policy (:modes))))
      (should-error (apply #'kargu-tool-registry-register registry arguments)))
    (should (equal (kargu-tool-registry-names registry) '("read")))
    (should (equal (kargu-tool-definition-description
                    (kargu-tool-registry-find registry "read")) "Read"))
    (should-error (kargu-tool-registry-find nil "read"))
    (should-error (kargu-tool-registry-find registry 7))))

(ert-deftest kargu-tool-registry-invalid-policy-keeps-old-policy-test ()
  "An invalid policy or unknown target cannot mutate the registered policy."
  (let ((registry (kargu-tool-registry-create)))
    (kargu-tool-registry-register registry :name "read" :description "Read"
                                  :executor #'ignore :policy '(:modes (ask)))
    (should-error (kargu-tool-registry-set-policy registry "read" '(:modes (bad))))
    (should-error (kargu-tool-registry-set-policy registry "missing" nil))
    (should (equal (kargu-tool-definition-policy
                    (kargu-tool-registry-find registry "read")) '(:modes (ask))))))

(ert-deftest kargu-tool-registry-missing-alias-target-is-a-noop-test ()
  "An unknown target never creates a dangling alias."
  (let ((registry (kargu-tool-registry-create)))
    (should-not (kargu-tool-registry-alias registry "r" "missing"))
    (should-not (kargu-tool-registry-names registry))
    (should (equal (kargu-tool-registry-canonical-name registry "missing")
                   "missing"))))

(ert-deftest kargu-tool-registry-alias-cannot-hide-canonical-tool-test ()
  "An alias collision cannot destroy a canonical definition or form a cycle."
  (let ((registry (kargu-tool-registry-create)))
    (dolist (name '("read" "write"))
      (kargu-tool-registry-register registry :name name :description name
                                    :executor #'ignore))
    (should-error (kargu-tool-registry-alias registry "read" "write"))
    (should (equal (kargu-tool-registry-alias registry "read" "read") "read"))
    (should (equal (kargu-tool-definition-name
                    (kargu-tool-registry-find registry "read")) "read"))))

(provide 'tests/test-tool-registry)
;;; test-tool-registry.el ends here
