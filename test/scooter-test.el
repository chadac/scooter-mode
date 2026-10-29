;;; scooter-test.el --- Tests for scooter-mode  -*- lexical-binding: t; -*-

(require 'ert)
(require 'scooter)

(ert-deftest scooter-test-slug ()
  (should (equal (scooter-slug "Fix the login redirect!" "abc") "fix-the-login-redirect"))
  (should (equal (scooter-slug "  --Ünïcode & spaces--  " "abc") "n-code-spaces"))
  (should (equal (scooter-slug nil "0123456789abcdef") "01234567"))
  (should (equal (scooter-slug "" "abc") "abc"))
  (should (<= (length (scooter-slug (make-string 60 ?a) "x")) 40)))

(ert-deftest scooter-test-groups ()
  (should (eq (scooter-list-group '((status . "running") (awaitingInputAt . 5) (runStartedAt . 1))) 'awaiting))
  (should (eq (scooter-list-group '((status . "running") (runStartedAt . 1))) 'running))
  (should (eq (scooter-list-group '((status . "running"))) 'idle))
  (should (eq (scooter-list-group '((status . "suspended"))) 'suspended))
  (should (eq (scooter-list-group '((status . "failed"))) 'failed)))

(ert-deftest scooter-test-auth-wall ()
  (should (scooter-http-auth-wall-p 401 "application/json"))
  (should (scooter-http-auth-wall-p 302 ""))
  (should (scooter-http-auth-wall-p 403 "text/html"))
  (should (scooter-http-auth-wall-p 200 "text/html; charset=utf-8"))
  (should-not (scooter-http-auth-wall-p 403 "application/json"))
  (should-not (scooter-http-auth-wall-p 404 "application/json"))
  (should-not (scooter-http-auth-wall-p 200 "application/json")))

(ert-deftest scooter-test-jwt-exp ()
  (let ((token (concat "e30." (base64url-encode-string "{\"exp\":1700000000}" t) ".sig")))
    (should (= (scooter-auth--jwt-exp token) 1700000000)))
  (should (= (scooter-auth--jwt-exp "garbage") 0)))

(ert-deftest scooter-test-pkce ()
  ;; Expected value computed independently with Perl's Digest::SHA.
  (should (equal (scooter-auth-pkce-challenge "dBjftJeZ4CVP-mJ92K1hgPLBEsl4XBO6pqR1Vie9rF8")
                 "niQw9d7JkLeYdv9DhxacziU9zeJo1l1b1rGVtP0T2i4"))
  (let ((a (scooter-auth--random 32)) (b (scooter-auth--random 32)))
    (should (= (length a) 43))
    (should-not (equal a b))))

(ert-deftest scooter-test-headers-json ()
  (let ((scooter-servers '((home :url "https://s.example" :auth cookie)
                           (dev :url "http://localhost:8080")))
        (scooter-auth--cache (make-hash-table :test #'eq)))
    (scooter-auth-set-cookie 'home "_oauth2_proxy=abc")
    (should (equal (json-parse-string (scooter-auth-headers-json "home") :object-type 'alist)
                   '((Cookie . "_oauth2_proxy=abc"))))
    (should (equal (scooter-auth-headers-json "dev") "{}"))))

(ert-deftest scooter-test-headers-command-keeps-placeholder ()
  (let ((server-socket-dir "/tmp/emacs-sock") (server-name "server"))
    (should (string-match-p "{retry})'\\'" (scooter-agent-shell-headers-command 'home)))))

(ert-deftest scooter-test-acp-arguments ()
  (let ((scooter-servers '((home :url "https://s.example/" :model "m1")))
        (scooter-acp-command '("scooter" "acp")))
    (cl-letf (((symbol-function 'scooter-agent-shell--headers-args) (lambda (_) '("--headers-file" "f"))))
      (should (equal (scooter-acp-arguments 'home :project t)
                     '("acp" "--server" "https://s.example" "--model" "m1" "--project" "--headers-file" "f"))))))

(defmacro scooter-test-with-fake-server (url-var &rest body)
  "Run BODY with URL-VAR bound to a fake Scooter's base URL."
  (declare (indent 1))
  `(let* ((proc (start-process "fake-scooter" (generate-new-buffer " *fake*") "emacs" "-Q" "--batch" "-l"
                               (expand-file-name "fake-server.el" (file-name-directory (or load-file-name buffer-file-name
                                                                                           (locate-library "scooter-test"))))))
          (port nil))
     (unwind-protect
         (progn
           (with-current-buffer (process-buffer proc)
             (with-timeout (10 (error "Fake server didn't start"))
               (while (not (string-match "^\\([0-9]+\\)$" (buffer-string)))
                 (accept-process-output proc 0.1)))
             (setq port (match-string 1 (buffer-string))))
           (let ((,url-var (format "http://127.0.0.1:%s" port)))
             ,@body))
       (delete-process proc))))

(ert-deftest scooter-test-request-retries-after-auth-wall ()
  (scooter-test-with-fake-server url
    (let ((scooter-servers `((home :url ,url :auth cookie)))
          (scooter-auth--cache (make-hash-table :test #'eq))
          (asked 0))
      (scooter-auth-set-cookie 'home "stale")
      (cl-letf (((symbol-function 'scooter-auth--secret) #'ignore)
                ((symbol-function 'read-passwd) (lambda (&rest _) (cl-incf asked) "good"))
                ((symbol-function 'y-or-n-p) #'ignore))
        (should (equal (scooter-request 'home "GET" "/whoami") '((id . "me"))))
        (should (= asked 1))
        ;; The fresh cookie is reused.
        (should (equal (scooter-request 'home "GET" "/whoami") '((id . "me"))))
        (should (= asked 1))))))

(ert-deftest scooter-test-request-gives-up-after-one-retry ()
  (scooter-test-with-fake-server url
    (let ((scooter-servers `((home :url ,url :auth cookie)))
          (scooter-auth--cache (make-hash-table :test #'eq)))
      (scooter-auth-set-cookie 'home "stale")
      (cl-letf (((symbol-function 'scooter-auth--secret) #'ignore)
                ((symbol-function 'read-passwd) (lambda (&rest _) "still-bad"))
                ((symbol-function 'y-or-n-p) #'ignore))
        (should-error (scooter-request 'home "GET" "/whoami") :type 'scooter-auth-wall)))))

(ert-deftest scooter-test-json-403-is-an-error-not-a-wall ()
  (scooter-test-with-fake-server url
    (let ((scooter-servers `((home :url ,url))))
      (let ((err (should-error (scooter-request 'home "POST" "/forbidden") :type 'scooter-http-error)))
        (should (string-match-p "not your conversation" (format "%s" err)))))))




(ert-deftest scooter-test-agent-shell-config-runs-the-bridge ()
  (let ((scooter-servers '((home :url "https://s.example")))
        (scooter-acp-command '("scooter" "acp")))
    (cl-letf (((symbol-function 'scooter-agent-shell--headers-args) (lambda (_) '("--headers-file" "f"))))
      (let* ((config (scooter-agent-shell-config 'home :title "fix-login"))
             (client (with-temp-buffer (funcall (map-elt config :client-maker) (current-buffer)))))
        (should (equal (map-elt config :buffer-name) "Scooter fix-login@home"))
        (should (member "--server" (map-elt client :command-params)))
        (should (equal (cons (map-elt client :command) (map-elt client :command-params))
                       '("scooter" "acp" "--server" "https://s.example" "--headers-file" "f")))))))

(provide 'scooter-test)
;;; scooter-test.el ends here
