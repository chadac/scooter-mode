;;; check-deps.el --- Fail on calls only declare-function vouches for  -*- lexical-binding: t; -*-

;; Usage: emacs -Q --batch -L lisp -l test/check-deps.el FILE.el
;; Compiles FILE in a fresh Emacs that knows only FILE's requires and the
;; package's autoloads, so a missing require shows up as an unknown function.

(require 'bytecomp)
(require 'loaddefs-gen)

(defconst check-deps-optional "\\`\\(agent-shell\\|acp\\|evil\\|projectile\\)-"
  "Functions from packages scooter uses only when they're installed.")

(let ((defs (expand-file-name "scooter-autoloads.el" (make-temp-file "scooter-loaddefs" t))))
  (loaddefs-generate (expand-file-name "lisp") defs)
  (load defs nil t))

;; Treat declare-function as a comment, so it can't hide a missing require.
(setq byte-compile-initial-macro-environment
      (assq-delete-all 'declare-function (copy-alist byte-compile-initial-macro-environment)))
(put 'declare-function 'byte-hunk-handler nil)
(defmacro declare-function (&rest _) nil)

(let* ((file (car command-line-args-left))
       (byte-compile-dest-file-function (lambda (_) (make-temp-file "check-deps" nil ".elc")))
       (warnings nil)
       (byte-compile-log-warning-function (lambda (msg &rest _) (push msg warnings)))
       (bad nil))
  (byte-compile-file file)
  (dolist (msg warnings)
    (dolist (name (cond ((string-match "function ‘\\([^’]+\\)’ is not known to be defined" msg)
                         (list (match-string 1 msg)))
                        ((string-match "not known to be defined:\\(\\(?:.\\|\n\\)*\\)" msg)
                         (split-string (match-string 1 msg) "[ ,.\n]+" t))))
      (unless (string-match-p check-deps-optional name) (push name bad))))
  (when bad
    (message "%s calls functions nothing loads: %s" file (string-join (nreverse bad) ", "))
    (kill-emacs 1)))
