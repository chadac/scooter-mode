;;; scooter-auth.el --- Auth for Scooter behind oauth2-proxy  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Chad Crawford
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Backends, chosen per server by its :auth setting:
;;
;; - `cookie': the `_oauth2_proxy' session cookie, pasted or read from
;;   auth-source.  Works with any oauth2-proxy, GitHub-backed ones included.
;; - (oidc :issuer URL :client-id ID): an ID token from Authorization Code +
;;   PKCE with a loopback redirect, sent as a bearer token.  oauth2-proxy
;;   must run with --skip-jwt-bearer-tokens.  The refresh token is kept in
;;   auth-source.

;;; Code:

(require 'cl-lib)
(require 'auth-source)
(require 'browse-url)
(require 'url-util)
(require 'scooter-server)
(require 'scooter-http)

(defcustom scooter-auth-login-timeout 300
  "Seconds to wait for a browser login to finish."
  :type 'integer
  :group 'scooter)

(defvar scooter-auth--cache (make-hash-table :test #'eq)
  "Server name to its auth state plist.")

(defun scooter-auth--backend (server)
  "Return SERVER's backend symbol and its settings, as (TYPE . PLIST)."
  (let ((auth (scooter-server-get server :auth)))
    (if (consp auth) auth (list auth))))

(defun scooter-auth-headers (server &optional retry)
  "Return the auth headers for SERVER as an alist.
RETRY non-nil means the last headers hit the auth wall."
  (when retry (scooter-auth-forget server))
  (pcase (scooter-auth--backend server)
    (`(nil) nil)
    (`(cookie) `(("Cookie" . ,(concat "_oauth2_proxy=" (scooter-auth--cookie server)))))
    (`(oidc . ,opts) `(("Authorization" . ,(concat "Bearer " (scooter-auth--id-token server opts)))))
    (other (user-error "Scooter[%s]: unknown :auth %S" server other))))

;;;###autoload
(defun scooter-auth-headers-json (server &optional retry)
  "Return SERVER's auth headers as a JSON string, for `scooter acp'.
RETRY is as in `scooter-auth-headers'."
  (let ((json-encoding-pretty-print nil))
    (let ((headers (scooter-auth-headers server retry)))
      (if headers (json-encode headers) "{}"))))

(defun scooter-auth-forget (server)
  "Drop SERVER's cached ID token and cookie; the next request logs in again."
  (interactive (list (scooter-current-server t)))
  (scooter-auth--put server :id-token nil :cookie nil :cookie-refused t))

(defun scooter-auth--get (server key)
  "Return SERVER's cached auth KEY."
  (plist-get (gethash (scooter-server--name server) scooter-auth--cache) key))

(defun scooter-auth--put (server &rest kvs)
  "Store KVS in SERVER's auth cache."
  (let ((state (gethash (scooter-server--name server) scooter-auth--cache)))
    (while kvs
      (setq state (plist-put state (pop kvs) (pop kvs))))
    (puthash (scooter-server--name server) state scooter-auth--cache)))

;;;; Cookie

(defun scooter-auth--cookie (server)
  "Return SERVER's oauth2-proxy cookie, asking when there is none."
  (or (scooter-auth--get server :cookie)
      ;; Once refused, a stored cookie is stale until replaced.
      (when-let* (((not (scooter-auth--get server :cookie-refused)))
                  (stored (scooter-auth--secret (scooter-server-host server) "_oauth2_proxy")))
        (scooter-auth--put server :cookie stored)
        stored)
      (scooter-auth-set-cookie server)))

;;;###autoload
(defun scooter-auth-set-cookie (server &optional cookie)
  "Set SERVER's `_oauth2_proxy' COOKIE, opening the login page to get one."
  (interactive (list (scooter-current-server t)))
  (unless cookie
    (when (y-or-n-p (format "Scooter[%s]: open the login page in a browser? " server))
      (browse-url (scooter-server-url server "/oauth2/sign_in")))
    (setq cookie (string-trim (read-passwd
                               (format "Scooter[%s] _oauth2_proxy cookie value: " server)))))
  (setq cookie (string-remove-prefix "_oauth2_proxy=" cookie))
  (scooter-auth--put server :cookie cookie :cookie-refused nil)
  cookie)

;;;; OIDC

(defun scooter-auth--secret (host user)
  "Return the auth-source secret for HOST and USER, or nil."
  (when-let* ((found (car (auth-source-search :host host :user user :max 1)))
              (secret (plist-get found :secret)))
    (if (functionp secret) (funcall secret) secret)))

(defun scooter-auth--save-secret (host user secret)
  "Save SECRET for HOST and USER through auth-source, if it can."
  (ignore-errors
    (auth-source-forget (list :host host :user user))
    (let ((found (car (auth-source-search :host host :user user :secret secret
                                          :create t :max 1))))
      (when-let* ((save (plist-get found :save-function)))
        (funcall save)))))

(defun scooter-auth--jwt-exp (token)
  "Return the exp claim of JWT TOKEN, or 0."
  (or (ignore-errors
        (let* ((payload (nth 1 (split-string token "\\.")))
               (pad (make-string (% (- 4 (% (length payload) 4)) 4) ?=))
               (json (base64-decode-string (concat payload pad) t)))
          (alist-get 'exp (scooter-http-parse (decode-coding-string json 'utf-8)))))
      0))

(defun scooter-auth--discovery (issuer)
  "Return ISSUER's OpenID discovery document."
  (pcase-let ((`(,status ,_ ,text)
               (scooter-http-curl "GET" (concat (string-trim-right issuer "/")
                                                "/.well-known/openid-configuration"))))
    (unless (= status 200)
      (user-error "OIDC discovery for %s failed: %d" issuer status))
    (scooter-http-parse text)))

(defun scooter-auth--token-request (endpoint form)
  "POST FORM (an alist) to the token ENDPOINT and return the reply."
  (pcase-let ((`(,status ,_ ,text)
               (scooter-http-curl "POST" endpoint
                                  :body (url-build-query-string
                                         (mapcar (lambda (kv) (list (car kv) (cdr kv))) form))
                                  :content-type "application/x-www-form-urlencoded")))
    (let ((reply (scooter-http-parse text)))
      (unless (= status 200)
        (error "Token request failed: %d %s" status (or (alist-get 'error reply) text)))
      reply)))

(defun scooter-auth--id-token (server opts)
  "Return a live ID token for SERVER configured by OPTS."
  (let ((token (scooter-auth--get server :id-token)))
    (if (and token (> (scooter-auth--jwt-exp token) (+ (float-time) 60)))
        token
      (or (ignore-errors (scooter-auth--refresh server opts))
          (scooter-auth-login server)))))

(defun scooter-auth--store (server opts reply)
  "Cache the tokens in REPLY for SERVER, persisting the refresh token per OPTS."
  (let ((id (alist-get 'id_token reply))
        (refresh (alist-get 'refresh_token reply)))
    (unless id (error "Scooter[%s]: the IdP returned no id_token" server))
    (scooter-auth--put server :id-token id)
    (when refresh
      (scooter-auth--put server :refresh-token refresh)
      (scooter-auth--save-secret (url-host (url-generic-parse-url (plist-get opts :issuer)))
                                 (plist-get opts :client-id) refresh))
    id))

(defun scooter-auth--refresh (server opts)
  "Refresh SERVER's ID token per OPTS, or return nil."
  (when-let* ((refresh (or (scooter-auth--get server :refresh-token)
                           (scooter-auth--secret
                            (url-host (url-generic-parse-url (plist-get opts :issuer)))
                            (plist-get opts :client-id)))))
    (let ((doc (scooter-auth--discovery (plist-get opts :issuer))))
      (scooter-auth--store
       server opts
       (scooter-auth--token-request
        (alist-get 'token_endpoint doc)
        `(("grant_type" . "refresh_token") ("refresh_token" . ,refresh)
          ("client_id" . ,(plist-get opts :client-id))))))))

(defun scooter-auth--random (n)
  "Return N random bytes, base64url-encoded."
  (base64url-encode-string
   (if (and (file-readable-p "/dev/urandom") (executable-find "head"))
       (with-temp-buffer
         (set-buffer-multibyte nil)
         (let ((coding-system-for-read 'binary))
           (call-process "head" "/dev/urandom" t nil "-c" (number-to-string n)))
         (buffer-string))
     ;; No OS entropy file: fall back to the seeded PRNG.
     (random t)
     (apply #'unibyte-string (cl-loop repeat n collect (random 256))))
   t))

(defun scooter-auth-pkce-challenge (verifier)
  "Return the S256 PKCE challenge for VERIFIER."
  (base64url-encode-string (secure-hash 'sha256 verifier nil nil t) t))

;;;###autoload
(defun scooter-auth-login (server)
  "Log in to SERVER's IdP in a browser; return the ID token."
  (interactive (list (scooter-current-server t)))
  (let* ((opts (cdr (scooter-auth--backend server)))
         (doc (scooter-auth--discovery (plist-get opts :issuer)))
         (verifier (scooter-auth--random 48))
         (state (scooter-auth--random 16))
         (result nil)
         (proc (make-network-process
                :name "scooter-oidc-callback" :server t :host "127.0.0.1" :service t
                :family 'ipv4 :noquery t
                :filter (lambda (conn text)
                          (when (string-match "\\`GET \\([^ ]+\\)" text)
                            (let* ((query (url-parse-query-string
                                           (or (cadr (split-string (match-string 1 text) "?")) "")))
                                   (get (lambda (k) (cadr (assoc k query)))))
                              (setq result (if (equal (funcall get "state") state)
                                               (or (funcall get "code")
                                                   (list 'error (funcall get "error")))
                                             (list 'error "state mismatch")))
                              (process-send-string
                               conn (concat "HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\n\r\n"
                                            "Scooter: you can close this tab.\n"))
                              (delete-process conn))))))
         (redirect (format "http://127.0.0.1:%d/callback" (process-contact proc :service))))
    (unwind-protect
        (progn
          (browse-url
           (concat (alist-get 'authorization_endpoint doc) "?"
                   (url-build-query-string
                    `(("response_type" "code")
                      ("client_id" ,(plist-get opts :client-id))
                      ("redirect_uri" ,redirect)
                      ("scope" ,(string-join (or (plist-get opts :scopes)
                                                 '("openid" "email" "profile" "offline_access"))
                                             " "))
                      ("state" ,state)
                      ("code_challenge" ,(scooter-auth-pkce-challenge verifier))
                      ("code_challenge_method" "S256")))))
          (message "Scooter[%s]: finish the login in your browser..." server)
          (with-timeout (scooter-auth-login-timeout
                         (user-error "Scooter[%s]: login timed out" server))
            (while (not result) (accept-process-output nil 0.2)))
          (when (consp result)
            (user-error "Scooter[%s]: login failed: %s" server (cadr result)))
          (prog1 (scooter-auth--store
                  server opts
                  (scooter-auth--token-request
                   (alist-get 'token_endpoint doc)
                   `(("grant_type" . "authorization_code") ("code" . ,result)
                     ("redirect_uri" . ,redirect) ("code_verifier" . ,verifier)
                     ("client_id" . ,(plist-get opts :client-id)))))
            (message "Scooter[%s]: logged in" server)))
      (delete-process proc))))

(provide 'scooter-auth)
;;; scooter-auth.el ends here
