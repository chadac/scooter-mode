;;; scooter-list.el --- Conversation list for Scooter  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Chad Crawford
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; `scooter-list' shows each server's conversations as `magit-section's,
;; grouped by status, and refreshes when /conversations/events reports a
;; change.

;;; Code:

(require 'cl-lib)
(require 'magit-section)
(require 'scooter-server)
(require 'scooter-http)
(require 'transient)

(declare-function scooter-open "scooter" (server id))
(declare-function scooter-new "scooter" (server text &optional model))
(declare-function scooter-dispatch "scooter")
(declare-function evil-set-initial-state "evil-core" (mode state))

(defface scooter-list-status '((t :inherit magit-section-heading))
  "Face for status group headings without a face of their own."
  :group 'scooter)

(defface scooter-list-awaiting '((t :inherit (warning bold)))
  "Face for the \"Awaiting you\" heading."
  :group 'scooter)

(defface scooter-list-running '((t :inherit (success bold)))
  "Face for the \"Running\" heading."
  :group 'scooter)

(defface scooter-list-failed '((t :inherit (error bold)))
  "Face for the \"Failed\" heading."
  :group 'scooter)

(defface scooter-list-star '((t :inherit font-lock-constant-face))
  "Face for the star on starred conversations."
  :group 'scooter)

(defface scooter-list-model '((t :inherit font-lock-type-face))
  "Face for the model column."
  :group 'scooter)

(defface scooter-list-dim '((t :inherit shadow))
  "Face for secondary columns."
  :group 'scooter)

(defconst scooter-list--groups
  '((awaiting "Awaiting you" scooter-list-awaiting)
    (running "Running" scooter-list-running)
    (idle "Idle" scooter-list-status)
    (suspended "Suspended" scooter-list-dim)
    (failed "Failed" scooter-list-failed))
  "Status groups in display order, with their labels and heading faces.")

(defvar-local scooter-list--servers nil
  "Servers this buffer shows.")

(defvar-local scooter-list--streams nil
  "Live event stream processes, one per server.")

(defvar-local scooter-list--refresh-timer nil
  "Pending debounced refresh.")

(defun scooter-list-group (conv)
  "Return the status group symbol for CONV, an alist."
  (let ((status (alist-get 'status conv)))
    (cond
     ((alist-get 'awaitingInputAt conv) 'awaiting)
     ((equal status "suspended") 'suspended)
     ((equal status "failed") 'failed)
     ((alist-get 'runStartedAt conv) 'running)
     (t 'idle))))

(defun scooter-slug (title &optional id)
  "Return the slug for TITLE, or ID's first 8 characters when untitled."
  (let ((slug (string-trim (replace-regexp-in-string "[^a-z0-9]+" "-" (downcase (or title ""))) "-+" "-+")))
    (if (string-empty-p slug)
        (substring (or id "") 0 (min 8 (length (or id ""))))
      (string-trim-right (substring slug 0 (min 40 (length slug))) "-+"))))

(defun scooter-list--age (ms)
  "Format epoch MS as a short age."
  (if (not (numberp ms)) ""
    (let ((s (- (float-time) (/ ms 1000.0))))
      (cond ((< s 3600) (format "%dm" (max 0 (/ s 60))))
            ((< s 86400) (format "%dh" (/ s 3600)))
            (t (format "%dd" (/ s 86400)))))))

(defclass scooter-server-section (magit-section) ())
(defclass scooter-group-section (magit-section) ())
(defclass scooter-conversation-section (magit-section) ())

(defvar-keymap scooter-list-mode-map
  :doc "Keymap for `scooter-list-mode'."
  :parent magit-section-mode-map
  "RET" #'scooter-list-open
  "c" #'scooter-list-new
  "s" #'scooter-list-star
  "t" #'scooter-list-retitle
  "k" #'scooter-list-cancel
  "z" #'scooter-list-suspend
  "f" #'scooter-list-files
  "w" #'scooter-list-copy-url
  "b" #'scooter-list-browse
  "g" #'scooter-list-refresh
  "?" #'scooter-list-dispatch)

(define-derived-mode scooter-list-mode magit-section-mode "Scooter"
  "Scooter conversations, grouped by server and status."
  (setq-local revert-buffer-function (lambda (&rest _) (scooter-list-refresh)))
  (add-hook 'kill-buffer-hook #'scooter-list--stop-streams nil t))

;; Evil's normal state would shadow every key here, `?' included.
(with-eval-after-load 'evil
  (evil-set-initial-state 'scooter-list-mode 'emacs))

(transient-define-prefix scooter-list-dispatch ()
  "Commands for the conversation list."
  [["Conversation at point"
    ("RET" "Open" scooter-list-open)
    ("s" "Star" scooter-list-star)
    ("t" "Retitle" scooter-list-retitle)
    ("k" "Stop run" scooter-list-cancel)
    ("z" "Suspend" scooter-list-suspend)]
   ["Links"
    ("f" "Files" scooter-list-files)
    ("b" "Browse" scooter-list-browse)
    ("w" "Copy URL" scooter-list-copy-url)]
   ["List"
    ("c" "New" scooter-list-new)
    ("g" "Refresh" scooter-list-refresh)
    ("S" "More Scooter commands" scooter-dispatch)]])

;;;###autoload
(defun scooter-list (&optional server)
  "List conversations on every server, or only SERVER with a prefix argument."
  (interactive (list (and current-prefix-arg (scooter-read-server))))
  (let ((buf (get-buffer-create (if server (format "*scooter: %s*" server) "*scooter*"))))
    (with-current-buffer buf
      (unless (derived-mode-p 'scooter-list-mode) (scooter-list-mode))
      (setq scooter-list--servers (if server (list server) (scooter-server-names)))
      (scooter-list-refresh)
      (scooter-list--start-streams))
    (pop-to-buffer-same-window buf)))

(defun scooter-list--fetch (server)
  "Return SERVER's conversations, or an error string."
  (condition-case err
      (cl-sort (seq-remove (lambda (c) (alist-get 'parentId c))
                           (scooter-request server "GET" "/conversations"))
               #'> :key (lambda (c) (or (alist-get 'lastActivityAt c) 0)))
    (error (error-message-string err))))

(defun scooter-list--insert-conversation (server conv)
  "Insert one row for CONV on SERVER."
  (magit-insert-section (scooter-conversation-section (cons server conv))
    (insert (if (eq (alist-get 'starred conv) t) (propertize "★ " 'face 'scooter-list-star) "  ")
            (string-pad (scooter-slug (alist-get 'title conv) (alist-get 'id conv)) 41)
            (propertize (string-pad (scooter-list--age (alist-get 'lastActivityAt conv)) 4 nil t)
                        'face 'scooter-list-dim)
            (when-let* ((model (alist-get 'model conv)))
              (concat "  " (propertize model 'face 'scooter-list-model)))
            "\n")))

(defun scooter-list--render (data)
  "Render DATA, a list of (SERVER . CONVERSATIONS-OR-ERROR)."
  (let ((inhibit-read-only t)
        (pos (point)))
    (erase-buffer)
    (magit-insert-section (root)
      (pcase-dolist (`(,server . ,convs) data)
        (magit-insert-section (scooter-server-section server)
          (magit-insert-heading
            (propertize (format "%s" server) 'face 'magit-section-heading)
            (propertize (format "  %s" (scooter-server-url server)) 'face 'scooter-list-dim))
          (if (stringp convs)
              (insert "  " (propertize convs 'face 'error) "\n")
            (pcase-dolist (`(,group ,label ,face) scooter-list--groups)
              (when-let* ((members (seq-filter (lambda (c) (eq (scooter-list-group c) group)) convs)))
                (magit-insert-section (scooter-group-section group (memq group '(suspended failed)))
                  (magit-insert-heading
                    (propertize (format "%s (%d)" label (length members)) 'face face))
                  (dolist (c members) (scooter-list--insert-conversation server c))))))
          (insert "\n"))))
    (goto-char (min pos (point-max)))))

(defun scooter-list-refresh ()
  "Refetch and redraw the list."
  (interactive)
  (scooter-list--render
   (mapcar (lambda (s) (cons s (scooter-list--fetch s))) scooter-list--servers)))

(defun scooter-list--schedule-refresh (buf)
  "Refresh BUF soon, coalescing bursts of change events."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (unless (timerp scooter-list--refresh-timer)
        (setq scooter-list--refresh-timer
              (run-at-time 1 nil
                           (lambda ()
                             (when (buffer-live-p buf)
                               (with-current-buffer buf
                                 (setq scooter-list--refresh-timer nil)
                                 (ignore-errors (scooter-list-refresh)))))))))))

(defun scooter-list--start-streams ()
  "Follow each shown server's change stream."
  (scooter-list--stop-streams)
  (let ((buf (current-buffer)))
    (dolist (server scooter-list--servers)
      (scooter-list--follow buf server))))

(defun scooter-list--follow (buf server)
  "Follow SERVER's change stream for BUF, reconnecting while BUF lives."
  (when (buffer-live-p buf)
    (let ((proc (ignore-errors
                  (scooter-http-stream server "/conversations/events"
                                       (lambda (frame)
                                         (unless (equal (alist-get 'kind frame) "snapshot")
                                           (scooter-list--schedule-refresh buf)))))))
      (when proc
        (set-process-sentinel
         proc (lambda (_p _e)
                (when (buffer-live-p buf)
                  (run-at-time 10 nil #'scooter-list--follow buf server))))
        (with-current-buffer buf (push proc scooter-list--streams))))))

(defun scooter-list--stop-streams ()
  "Stop this buffer's change streams."
  (dolist (p scooter-list--streams)
    (set-process-sentinel p #'ignore)
    (delete-process p))
  (setq scooter-list--streams nil))

(defun scooter-list--at-point ()
  "Return (SERVER . CONVERSATION) at point, or signal."
  (let ((section (magit-current-section)))
    (or (and (cl-typep section 'scooter-conversation-section) (oref section value))
        (user-error "No conversation here"))))

(defun scooter-list--server-at-point ()
  "Return the server whose section contains point."
  (let ((s (magit-current-section)))
    (while (and s (not (cl-typep s 'scooter-server-section)))
      (setq s (oref s parent)))
    (if s (oref s value) (scooter-current-server))))

(defun scooter-list--id (entry) (alist-get 'id (cdr entry)))

(defun scooter-list-open ()
  "Open the conversation at point in agent-shell."
  (interactive)
  (let ((e (scooter-list--at-point)))
    (scooter-open (car e) (scooter-list--id e))))

(defun scooter-list-new (text)
  "Start a conversation on the server at point with TEXT."
  (interactive (list (read-string "New conversation: ")))
  (scooter-new (scooter-list--server-at-point) text))

(defun scooter-list-star ()
  "Toggle the star on the conversation at point."
  (interactive)
  (let ((e (scooter-list--at-point)))
    (scooter-request (car e) "PATCH" (format "/conversations/%s/starred" (scooter-list--id e))
                     `((starred . ,(if (eq (alist-get 'starred (cdr e)) t) :json-false t))))
    (scooter-list-refresh)))

(defun scooter-list-retitle (title)
  "Set the conversation at point's TITLE."
  (interactive (list (read-string "Title: " (alist-get 'title (cdr (scooter-list--at-point))))))
  (let ((e (scooter-list--at-point)))
    (scooter-request (car e) "PATCH" (format "/conversations/%s/title" (scooter-list--id e))
                     `((title . ,title)))
    (scooter-list-refresh)))

(defun scooter-list-cancel ()
  "Stop the run of the conversation at point."
  (interactive)
  (let ((e (scooter-list--at-point)))
    (when (yes-or-no-p (format "Stop the run in %s? " (scooter-slug (alist-get 'title (cdr e)) (scooter-list--id e))))
      (scooter-request (car e) "POST" (format "/conversations/%s/cancel" (scooter-list--id e))))))

(defun scooter-list-suspend ()
  "Suspend the sandbox of the conversation at point."
  (interactive)
  (let ((e (scooter-list--at-point)))
    (scooter-request (car e) "POST" (format "/conversations/%s/suspend" (scooter-list--id e)))
    (scooter-list-refresh)))

(defun scooter-list--url (entry &optional files)
  "Return ENTRY's browser URL, or its files viewer when FILES."
  (scooter-server-url (car entry)
                      (if files (format "/c/%s/files/" (scooter-list--id entry))
                        (format "/chat/%s" (scooter-list--id entry)))))

(defun scooter-list-files ()
  "Open the files viewer of the conversation at point in a browser."
  (interactive)
  (browse-url (scooter-list--url (scooter-list--at-point) t)))

(defun scooter-list-browse ()
  "Open the conversation at point in a browser."
  (interactive)
  (browse-url (scooter-list--url (scooter-list--at-point))))

(defun scooter-list-copy-url ()
  "Copy the browser URL of the conversation at point."
  (interactive)
  (let ((url (scooter-list--url (scooter-list--at-point))))
    (kill-new url)
    (message "Copied %s" url)))

(provide 'scooter-list)
;;; scooter-list.el ends here
