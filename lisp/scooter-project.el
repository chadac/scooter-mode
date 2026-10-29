;;; scooter-project.el --- Scooter in project.el and Projectile  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Chad Crawford
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Adds `scooter-new-from-project' to `C-x p p' and to Projectile's
;; commander and command map, each only once that package loads.

;;; Code:

(require 'scooter)

(defvar project-switch-commands)
(defvar projectile-command-map)
(declare-function def-projectile-commander-method "projectile")

(with-eval-after-load 'project
  (when (listp project-switch-commands)
    (add-to-list 'project-switch-commands '(scooter-new-from-project "Scooter" ?S) t)))

(with-eval-after-load 'projectile
  (keymap-set projectile-command-map "S" #'scooter-new-from-project)
  (eval '(def-projectile-commander-method ?S
           "Start a Scooter conversation about the project."
           (call-interactively #'scooter-new-from-project))
        t))

(provide 'scooter-project)
;;; scooter-project.el ends here
