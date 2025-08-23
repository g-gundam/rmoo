;;; rmoo.el --- a major mode for interacting with MOOs.
;;
;; Original Author: Ron Tapia <tapia@nmia.com>
;;                  Matthew Campbell <mattcampbell@pobox.com>
;;                  lisdude <lisdude@lisdude.com>
;; Version: 1.3
;; Package-Requires: (xterm-color)
;;
(provide 'rmoo)
(require 'cl-lib)
(require 'comint) ; All that's needed from comint is comint-read-noecho.
(require 'xterm-color)

;;
;; Most of the global variables.
;;
(defvar rmoo-version "1.3b")
(defgroup rmoo nil "Customization options for RMOO MOO client.")
(defvar rmoo-world-here nil "The moo world associated with this buffer.")
(make-variable-buffer-local 'rmoo-world-here)
(defvar rmoo-prompt ">" "The prompt to use for this moo.\nTaken from the prompt property of a moo world.")
(make-variable-buffer-local 'rmoo-prompt)
(defvar rmoo-handle-text-hooks nil "A list of hooks run every time that output from a MOO is entered in a moo interactive buffer.")
(defvar rmoo-interactive-mode-syntax-table nil "Syntax table for use with MOO interactive mode.")
(defvar rmoo-interactive-mode-hooks nil "A list of hooks run when a buffer changes to MOO interactive mode.")
(defcustom rmoo-autologin t "If a world has a login property, use it to automatically connect when rmoo is run." :group 'rmoo :type 'boolean)
(defvar rmoo-tls nil "Indicate whether a connection should use TLS.\nTaken from the tls property of a MOO world.")
(make-variable-buffer-local 'rmoo-tls)
(defvar rmoo-logfile nil "The path of the world's log file\nTaken from the logfile property of a MOO world.")
(make-variable-buffer-local 'rmoo-logfile)
(defcustom rmoo-connect-function 'open-network-stream "The function called to open a network connection.\nThis is useful if, for instance, you want to use a SOCKS proxy by replacing the connection function with something like socks-open-network-stream." :group 'rmoo :type 'function)
(defcustom rmoo-local-echo-color "#FFA500" "The color applied to the text that echos your input back to you." :group 'rmoo :type 'color)
(defcustom rmoo-clear-local t "Clear local variables (including command recall) when connecting to a new world in an existing buffer." :group 'rmoo :type 'boolean)
(defcustom rmoo-convert-utf-to-ascii t "Convert common UTF characters to their ASCII equivalents when sending commands." :group 'rmoo :type 'boolean)

(defvar rmoo-interactive-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map "\r" 'rmoo-send)
    (define-key map "\^a" 'rmoo-beginning-of-line)
    (define-key map "\^i" 'dabbrev-expand)
    (define-key map "\^c\^q" 'rmoo-quit)
    (define-key map "\^c\^y" 'rmoo-send-kill)
    (define-key map "\^c\^w" 'rmoo-worlds-map)
    (define-key map [backspace] 'rmoo-backspace)
    (define-key map "\^?" 'rmoo-backspace) ;; macOS Terminal
    (define-key map (kbd "C-c C-l") 'rmoo-set-linelength)
    (define-key map (kbd "M-DEL") 'rmoo-clear-input)
    (define-key map [up] 'rmoo-up-command)
    (define-key map [down] 'rmoo-down-command)
    (define-key map [home] 'rmoo-beginning-of-line)
    (define-key map (kbd "M-SPC") 'rmoo-jump-to-last-input)
    map)
  "Keymap for MOO Interactive Mode.")

(defvar rmoo-setup-done nil
  "Indicates whether rmoo-setup has executed yet.")

;;;###autoload
(defun rmoo (world)
  "Opens a connection to a MOO and sets up a rmoo-interactive-mode buffer."
  (interactive (list (rmoo-request-world)))
  (unless rmoo-setup-done
    (rmoo-setup))
  (let ((buf-name (concat "*" (symbol-name world) "*")))
    (if (memq (get-buffer-process buf-name) (process-list))
	(switch-to-buffer buf-name)
      (let* ((buf (get-buffer-create buf-name))
	     (site (rmoo-request-site-maybe world))
	     (port (rmoo-request-port-maybe world))
         (tls (rmoo-request-tls-maybe world))
         (coldc (rmoo-request-coldc-maybe world))
   	     (logfile (rmoo-request-logfile-maybe world))
	     (login (rmoo-request-login-maybe world))
	     (passwd (rmoo-request-passwd-maybe world))
	     (proc (if (string-match "^[.0-9]+$" site)
                (funcall rmoo-connect-function site buf site port)
                (funcall rmoo-connect-function site buf site port :type tls ))))
		(set-network-process-option proc :keepalive t)
	(put world 'process proc)
	(or (get world 'output-function)
	    (put world 'output-function 'rmoo-handle-text))
	(process-query-on-exit-flag proc)
	(if (and (not (string= login ""))
		 rmoo-autologin)
	    (rmoo-send-string (concat "connect "
				      login " "
				      passwd)
			      proc))
	(switch-to-buffer buf-name)
	(put world 'output-buffer (current-buffer))
	(rmoo-interactive-mode world)))))

(defun rmoo-interactive-mode (world)
  "Major mode for talking to inferior MOO processes.

Commands:
\\{rmoo-interactive-mode-map}

Hooks:
  rmoo-interactive-mode-hooks
  rmoo-handle-text-hooks

Abnormal hook:
  rmoo-handle-text-redirect-functions
  rmoo-send-hooks

Keymap:
  rmoo-interactive-mode-map"

  (interactive (rmoo-request-world))
  (if (null (get world 'process))
      (error "No process"))
(if rmoo-clear-local
  (kill-all-local-variables))
  (setq rmoo-world-here world)
  (set-process-filter (get world 'process) 'rmoo-filter)
  (setq mode-name "RMOO")
  (setq major-mode 'rmoo-interactive-mode)
  (setq fill-column (1- (window-width)))
  (if (null rmoo-interactive-mode-syntax-table)
      (progn
	(setq rmoo-interactive-mode-syntax-table (make-syntax-table))
	(set-syntax-table rmoo-interactive-mode-syntax-table)
	(modify-syntax-entry ?\[ "(]")
	(modify-syntax-entry ?\] ")[")
	(modify-syntax-entry ?# "w")))
  (use-local-map (copy-keymap rmoo-interactive-mode-map))
  (newline)
  (goto-char (point-max))
  (setq rmoo-prompt (or (get rmoo-world-here 'prompt) rmoo-prompt))
  (setq rmoo-logfile (or (get rmoo-world-here 'logfile) rmoo-logfile))
  (setq rmoo-tls (or (get rmoo-world-here 'tls) rmoo-tls))
  (set-marker (process-mark proc) (point))
  (insert rmoo-prompt)
  (run-hooks 'rmoo-interactive-mode-hooks))

;;
;; rmoo-filter doesn't run any hooks, but rmoo-handle-text does.
;;
(defun rmoo-filter (proc string)
  (let ((old-buf (current-buffer))
	goto-func goto-buf)
	(unwind-protect
	    (let (moving)
	      (set-buffer (process-buffer proc))
	      (setq moving (= (point) (process-mark proc)))
	      (save-excursion
		(let ((rmoo-output
		       (rmoo-string-to-list (concat (get rmoo-world-here
							'pending-output)
						   string)))
		      line)
		  (put rmoo-world-here 'pending-output (car rmoo-output))
		  (setq rmoo-output (cdr rmoo-output))
		  (while rmoo-output
		    (set-buffer (process-buffer proc))
            (setq line (decode-coding-string (car rmoo-output) 'latin-9 t))
		    (setq line (xterm-color-filter line))
;;            (set-text-properties line `(help-echo "TIMESTAMP"))
		    (setq rmoo-output (cdr rmoo-output))
		    (funcall (get rmoo-world-here 'output-function) line))))
	      (if moving (goto-char (process-mark proc))))
	  (set-buffer old-buf))
	;;
	;; This needs to be cleaned up.
	;;
	(if (fboundp (setq goto-func (get rmoo-world-here 'goto-function)))
	    (progn
	      (funcall goto-func
		       (get rmoo-world-here 'goto-buffer))
	      (put rmoo-world-here 'goto-function nil)
	      (put rmoo-world-here 'goto-buffer nil)))))

;;
;; Note that a moo output-function can always expect to be called in
;; the process buffer.
;;

;;
;; If an output function wants to take control from whatever
;; is handling the output currently, it can call:
;;
(defun rmoo-take-control-of-output (new-func)
  (put rmoo-world-here 'last-output-function
       (get rmoo-world-here 'output-function))
  (put rmoo-world-here 'output-function new-func))

;;
;; If an output function wants to hand control back the previous
;; output function, it can call:
(defun rmoo-output-function-return-control-to-last ()
  (interactive)
  (let ((last-func (get rmoo-world-here 'last-output-function)))
    (put rmoo-world-here 'last-output-function
	 (get rmoo-world-here 'output-function))
    (put rmoo-world-here 'output-function last-func)))

;;
;; If an output function wants to reset the output buffer
;; it can call one of:
;;
(defun rmoo-set-output-buffer-to-last ()
  (interactive)
  (let ((last-buf (get rmoo-world-here 'last-output-buffer)))
    (put rmoo-world-here 'last-output-buffer
	 (get rmoo-world-here 'output-buffer))
    (put rmoo-world-here 'output-buffer last-buf)))

(defun rmoo-set-output-buffer-to (buf)
  (put rmoo-world-here 'last-output-buffer
       (get rmoo-world-here 'output-buffer))
  (put rmoo-world-here 'output-buffer buf))

;;
;; By default rmoo.el just inserts lines of text in the process buffer.
;; More intelligent functions can be put in the MOO's output-function
;; property. If the default behavior suffices most of the time but you'd
;; like your function called on certain lines, put a matching function in
;; rmoo-handle-text-redirect-functions.
;;
(defvar rmoo-handle-text-redirect-functions nil "Functions called on each line of output. Each function in this list should take one argument, a string, and return a function (which is called on the line) or nil.")

(defun rmoo-handle-text-need-new-output-function (line)
  (let ((funcs rmoo-handle-text-redirect-functions)
	func
	rfunc)
    (while (and funcs (not rfunc))
      (setq func (car funcs))
      (setq funcs (cdr funcs))
      (setq rfunc (funcall func line)))
    rfunc))

;;
;; rmoo-handle-text checks to see if anybody wants to handle a line passed
;; to it, if someone does, it passes the line. If not, the line gets
;; inserted in the current buffer which is presumably the process buffer
;; of a MOO process.
;;
(defun rmoo-handle-text (line)
  (let (new-handler)
    (if (setq new-handler (rmoo-handle-text-need-new-output-function line))
	(apply new-handler (list line))
      (let (start end)
	(setq start (goto-char (marker-position
				(process-mark
				 (get rmoo-world-here 'process)))))
	(insert-before-markers (concat line "\n"))
	(save-restriction
      (narrow-to-region start (point))
	  (goto-char start)
	  (run-hooks 'rmoo-handle-text-hooks)
	  (rmoo-recenter))))))

;;
;; rmoo-handle-text doesn't automatically give control to a new handler
;; if a handler wants to control the output, it should call
;; something like rmoo-take-control-of-output
;;


;;
;; MOO worlds.
;;
;;
;; Some properties of moo worlds:
;;
;;                  login
;;                  password
;;                  site
;;                  port
;;                  tls
;;                  coldc
;;                  logfile
;;                  process
;;                  pending-output
;;                  output-buffer
;;                  output-function
;;                  last-output-buffer
;;                  last-output-function
;;                  goto-buffer
;;

(defvar rmoo-worlds-max-worlds 100 "The maximum number of MOO's")
(defvar rmoo-worlds (make-vector rmoo-worlds-max-worlds 0 ))
(defvar rmoo-worlds-add-rmoo-functions nil "A list of functions run every time that a MOO world is added. Each function in this list should take a single argument, a rmoo-world.")
(defvar rmoo-worlds-properties-to-save '(login passwd site port tls coldc logfile))
(defvar rmoo-worlds-file (expand-file-name "~/.rmoo_worlds") "The name of a file containing MOO worlds.")
(defvar rmoo-worlds-map (make-sparse-keymap) "MOO worlds keymap")

(define-key rmoo-interactive-mode-map "\C-c\C-w" rmoo-worlds-map)
(define-key rmoo-worlds-map "\C-a" 'rmoo-worlds-add-new-moo)
(define-key rmoo-worlds-map "\C-s" 'rmoo-worlds-save-worlds-to-file)

(defun rmoo-worlds-add-moo (world-name &rest pairs)
  (setq world (intern world-name rmoo-worlds))
  (let (pair prop)
    (while pairs
      (setq pair (car pairs))
      (setq pairs (cdr pairs))
      (put world (intern (car pair)) (car (cdr pair)))))
  (let ((funcs rmoo-worlds-add-rmoo-functions)
	func)
    (while funcs
      (setq func (car funcs))
      (setq funcs (cdr funcs))
      (funcall func world))))

;;;###autoload
(defun rmoo-worlds-add-new-moo (name site port tls coldc logfile)
  (interactive
    (list
      (read-string "World name: ")
      (read-string "Site: ")
      (string-to-number (read-string "Port: "))
      (yes-or-no-p "TLS/SSL? ")
      (yes-or-no-p "Is world ColdC? ")
      (read-string "Log File Path: ")
    ))
  (if tls
    (setq tls 'tls)
    (setq tls 'network))
  (if (string="" logfile)
    (setq logfile nil))
  (rmoo-worlds-add-moo name (list "site" site) (list "port" port) (list "tls" tls) (list "coldc" coldc) (list "logfile" logfile)))

(defun rmoo-worlds-save-worlds-to-file ()
  "Save rmoo-world-here's worlds to rmoo-worlds-file if it's not \"\". Otherwise, prompt for a file name and save there."
  (interactive)
  (let* ((world rmoo-world-here)
	 (file rmoo-worlds-file)
	 buf)
    (if (string= file "")
	(setq file (read-file-name "File: ")))
    (save-excursion
      (setq buf (get-buffer-create (generate-new-buffer-name (concat "*"
								     file
								     "*"))))
      (set-buffer buf)
      (insert ";;\n;; MOO Worlds\n;;\n")
      (mapatoms 'rmoo-worlds-insert-world rmoo-worlds)
      (write-file file)
      (set-file-modes file #o0600)
      (kill-buffer nil))))

(defun rmoo-worlds-insert-world (world)
  (let ((props rmoo-worlds-properties-to-save)
	prop)
    (insert "(rmoo-worlds-add-moo " (prin1-to-string (symbol-name world)))
    (while props
      (setq prop (car props))
      (setq props (cdr props))
      (insert "\n        '(" (prin1-to-string (symbol-name prop))
	      " "
	      (prin1-to-string (get world prop))
	      ")"))
    (insert ")\n\n")))

;;
;; Load world-specific lisp file.
;;
(defun rmoo-init-hook ()
  (let (file)
    (if (setq file (get rmoo-world-here 'world-init-file))
	(load-file (expand-file-name file)))))

;;
;; Make sure that world init files get saved.
;;
(setq rmoo-worlds-properties-to-save
      (append rmoo-worlds-properties-to-save '(world-init-file)))

;;
;; Run rmoo-init-hook whenever rmoo-interactive-mode starts.
;;
(add-hook 'rmoo-interactive-mode-hooks 'rmoo-init-hook)

;;;
;;; Input History Maintenance
;;;
(defcustom rmoo-input-history-size 150 "The number of lines to remember in input history." :group 'rmoo :type 'integer)

(defvar rmoo-input-history nil)

(defvar rmoo-input-index 0)

(defun rmoo-make-history (size)
  ;; (head tail . vector)
  ;; head is the index of the most recent item in the history.
  ;; tail is the index one past the oldest item
  ;; if head == tail, the history is empty
  ;; all index arithmetic is mod the size of the vector
  (cons 0 (cons 0 (make-vector (+ size 1) nil))))

(defun rmoo-decr-mod (n m)
  (if (= n 0)
      (1- m)
    (1- n)))

(defun rmoo-history-insert (history element)
  (let* ((head (car history))
	 (tail (car (cdr history)))
	 (vec (cdr (cdr history)))
	 (size (length vec))
	 (new-head (rmoo-decr-mod head size)))
    (aset vec new-head element)
    (setcar history new-head)
    (if (= new-head tail)  ; history is full, so forget oldest element
	(setcar (cdr history) (rmoo-decr-mod tail size)))))

(defun rmoo-history-empty-p (history)
  (= (car history) (car (cdr history))))

(defun rmoo-history-ref (history index)
  (let* ((head (car history))
	 (tail (car (cdr history)))
	 (vec (cdr (cdr history)))
	 (size (if (<= head tail)
		   (- tail head)
		 (+ tail (- (length vec) head)))))
    (if (= size 0)
	(error "Ref of an empty history")
      (let ((i (% index size)))
	(if (< i 0)
	    (setq i (+ i size)))
	(aref vec (% (+ head i) (length vec)))))))

(defun rmoo-initialize-input-history ()
  (if (or (null rmoo-input-history) rmoo-clear-local)
  (progn
  (make-local-variable 'rmoo-input-history)
  (make-local-variable 'rmoo-input-index)
  (make-local-variable 'rmoo-last-input-pos)
  (setq rmoo-input-history (rmoo-make-history rmoo-input-history-size))
  (setq rmoo-input-index 0)
  (setq rmoo-last-input-pos (point)))))

(defun rmoo-remember-input (string)
  (if (not (string= string ""))
    (progn
      (rmoo-history-insert rmoo-input-history string)
      (rmoo-append-to-logfile (concat rmoo-prompt string))
      (setq rmoo-last-input-pos (point)))))

(defun rmoo-previous-command ()
  (interactive)
  (rmoo-browse-input-history 1))

(defun rmoo-next-command ()
  (interactive)
  (rmoo-browse-input-history -1))

(defun rmoo-browse-input-history (delta)
  (cond ((rmoo-history-empty-p rmoo-input-history)
	 (error "You haven't typed any commands yet!"))
	((eq last-command 'rmoo-browse-input-history)
	 (setq rmoo-input-index (+ rmoo-input-index delta)))
	((save-excursion (eq (rmoo-find-input) (point)))
	 (setq rmoo-input-index 0))
	(t
	 (ding)
	 (message "Press %s again to erase line."
		  (key-description (this-command-keys)))
	 (setq delta nil)))
  (setq this-command 'rmoo-browse-input-history)
  (if delta
      (let ((end (rmoo-find-input)))
	(delete-region (point) end)
	(insert (rmoo-history-ref rmoo-input-history rmoo-input-index)))))

(defun rmoo-match-input-history (delta)
  (message (prin1-to-string last-command))
  (cond ((rmoo-history-empty-p rmoo-input-history)
	 (error "You haven't typed any commands yet!"))
	((eq last-command 'rmoo-match-input-history)
	 (setq rmoo-input-index (+ rmoo-input-index delta)))
	(t
	 (setq rmoo-input-index 0)))
  (setq this-command 'rmoo-match-input-history)
  (let* ((str (concat "^"
		      (regexp-quote (save-excursion
				      (buffer-substring (rmoo-find-input)
							(point))))))
	 (tail (nth 1 rmoo-input-history))
	 (vec (nthcdr 2 rmoo-input-history))
	 (size (length vec))
	 (found-match nil))
    (while (not (or (eq rmoo-input-index
			(+ rmoo-input-index (* delta size)))
		    found-match))
      (if (string-match str (rmoo-history-ref rmoo-input-history
					     rmoo-input-index))
	  (progn
	    (setq found-match t)
	    (delete-region (rmoo-find-input) (point))
	    (insert (rmoo-history-ref rmoo-input-history rmoo-input-index)))
	(setq rmoo-input-index (+ rmoo-input-index delta))))
    (if (not found-match)
	(error "No match in input history."))))

(defun rmoo-previous-matching-command ()
  (interactive)
  (rmoo-match-input-history -1))

(defun rmoo-jump-to-last-input ()
  "Jump to line after your last command was sent."
  (interactive)
  (goto-char rmoo-last-input-pos)
  (rmoo-beginning-of-line)
  (if (and (bound-and-true-p evil-mode) (not (eq evil-state 'normal)))
    (evil-normal-state nil)))

(add-hook 'rmoo-interactive-mode-hooks 'rmoo-initialize-input-history)
(add-hook 'rmoo-interactive-mode-hooks 'rmoo-clear-input)
(add-hook 'rmoo-send-functions 'rmoo-remember-input)

(define-key rmoo-interactive-mode-map "\ep" 'rmoo-previous-command)
(define-key rmoo-interactive-mode-map "\en" 'rmoo-next-command)

;;
;; Various reading functions.
;;
(defun rmoo-request-world ()
  (intern (completing-read "MOO world: " rmoo-worlds nil t) rmoo-worlds))

(defun rmoo-request-site-maybe (world)
  (or (get world 'site)
      (read-string "Site: ")))

(defun rmoo-request-port-maybe (world)
  (or (get world 'port)
      (string-to-number (read-string "Port: "))))

(defun rmoo-request-tls-maybe (world)
  (or (get world 'tls)
      (if (yes-or-no-p "TLS/SSL? ")
          'tls
          'network)))

(defun rmoo-request-login-maybe (world)
  (or (get world 'login)
      (read-string "Login as: ")))

(defun rmoo-request-passwd-maybe (world)
  (or (get world 'passwd)
      (comint-read-noecho "Password: " t)))

;; The functions below won't prompt when nil, as nil is a valid preference for them.
(defun rmoo-request-coldc-maybe (world)
  (get world 'coldc))

(defun rmoo-request-logfile-maybe (world)
  (get world 'logfile))
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;
;; RMOO setup
;;

(defvar rmoo-libraries
	(list
	"rmoo-mcp"
	"prefix"
	"moocode-mode"
	"rmoo-list"
	"rmoo-mail"
	"rmoo-objects"
	"rmoo-local-edit"
	"rmoo-extras"
    "rmoo-scratch"))

(defvar rmoo-x-libraries
      (list
       "rmoo-display-jtext"
       "rmoo-rmail"
       "rmoo-menus"))

;;;###autoload
(defun rmoo-setup ()
  (mapcar 'load-library rmoo-libraries)
  (if (string= window-system "x")
      (mapcar 'load-library rmoo-x-libraries))
  (if (featurep 'emacspeak)
      (load-library "emacspeak-rmoo"))
  (setq rmoo-setup-done t))

(if (file-exists-p (expand-file-name rmoo-worlds-file))
    (load-file (expand-file-name rmoo-worlds-file)))

;;
;;
;; Various utility functions:
;;
;;
(defun rmoo-backspace ()
  (interactive)
  (if (/= (current-column) (length rmoo-prompt))
      (delete-char -1)))

(defvar utf-to-ascii-table
  (let ((table (make-hash-table :test 'equal)))
    (puthash "“" "\"" table)
    (puthash "”" "\"" table)
    (puthash "„" "\"" table)
    (puthash "«" "\"" table)
    (puthash "»" "\"" table)
    (puthash "‘" "'" table)
    (puthash "’" "'" table)
    (puthash "‚" "'" table)
    (puthash "‹" "'" table)
    (puthash "›" "'" table)
    (puthash "—" "-" table)
    (puthash "–" "-" table)
    (puthash "‒" "-" table)
    (puthash "−" "-" table)
    (puthash "…" "..." table)
    (puthash "•" "*" table)
    (puthash "‣" "*" table)
    (puthash "⁃" "-" table)
    (puthash " " " " table) ;; Non-breaking space
    (puthash "°" " degrees" table)
    (puthash "×" "x" table)
    (puthash "±" "+/-" table)
    table)
  "Hash table for converting UTF characters to ASCII equivalents.")

(defvar utf-to-ascii-regex
  (regexp-opt (hash-table-keys utf-to-ascii-table))
  "Regex for UTF to ASCII conversion.")

(defun utf-to-ascii (string)
  "Convert UTF characters to their ASCII equivalents."
  (replace-regexp-in-string utf-to-ascii-regex
                            (lambda (match) (gethash match utf-to-ascii-table))
                            string))

(defun rmoo-send-string (string proc)
  "Send STRING as input to PROC, converting UTF characters to ASCII when rmoo-convert-utf-to-ascii is enabled."
  (let ((converted-string (if rmoo-convert-utf-to-ascii
                            (utf-to-ascii string)
                            string)))
    (comint-send-string proc (concat converted-string "\n"))))

(defun rmoo-eobp ()
  (cond ((eobp)
	 t)
	((looking-at ".*\\S-")
	 nil)
	(t
	 (forward-line)
	 (rmoo-eobp))))

(defun rmoo-beginning-of-line ()
  "Move point to beginning-of-line, but after prompt character."
  (interactive)
  (beginning-of-line 1)
  (if (looking-at rmoo-prompt)
      (forward-char (length rmoo-prompt))))

(defun rmoo-find-input ()
  "Move point to rmoo-beginning-of-line, and return end-of-line."
  (end-of-line 1)
  (prog1
      (point)
    (rmoo-beginning-of-line)))

(defvar rmoo-send-functions nil "A list of functions called everytime a line of input is send to a MOO process as a command in rmoo-interactive-mode. Each function is called with one argument, the line to be sent.")

(defcustom rmoo-send-always-goto-end nil "Indicates that RMOO should always go to the buffer after sending a line, no matter where in the buffer the user was." :group 'rmoo :type 'boolean)

(defcustom rmoo-send-require-last-line nil  "Indicates that RMOO should refuse to send what you type if you are not on the last line of the buffer." :group 'rmoo :type 'boolean)

(defun rmoo-send ()
  "Send current line of input to a MOO (rmoo-world-here)."
  (interactive)
  (if (and rmoo-send-require-last-line
   (not (save-excursion
     (end-of-line)
     (rmoo-eobp))))
    (progn
      (ding)
      (message "Must be on the last line of the buffer."))
    (progn
      (let ((proc (get rmoo-world-here 'process)))
        (cond ((and proc (memq (process-status proc) '(open run)))
    	   ;; process exists, send line
    	   (let* ((origin (point))
    		  (end (rmoo-find-input))
    		  (line (buffer-substring (point) end))
		  (funcs rmoo-send-functions)
		  func)
  	     (add-face-text-property (+ (line-beginning-position) (length rmoo-prompt)) (line-end-position) (cons 'foreground-color rmoo-local-echo-color))
	     (rmoo-send-here line)
	     (cond ((save-excursion
		      (end-of-line)
		      (or rmoo-send-always-goto-end (rmoo-eobp)))
		    (goto-char (point-max))
		    (insert ?\n)
		    (move-marker (process-mark proc) (point))
		    (insert rmoo-prompt)
		    (if (= scroll-step 1)
			(recenter -1)))
		   (t
		    (message "Sent line \"%s\"" line)
		    (goto-char origin)))
	     (while funcs
	       (setq func (car funcs))
	       (setq funcs (cdr funcs))
	       (funcall func line))))

	  (t
	   (message "Not connected--- nothing sent.")
	   (insert ?\n)))))))

(defun rmoo-send-here (string)
  "Send STRING as input to rmoo-world-here."
  (rmoo-send-string string (get rmoo-world-here 'process)))

(defun rmoo-recenter ()
  "If we should recenter, recenter."
  (if (and (eq (current-buffer) (process-buffer proc))
		   (eq scroll-step 1)
		   (= (point) (point-max)))
	(recenter -1)))

(defun rmoo-string-to-list (string)
  (let ((list nil))
    (while (string-match "\^m?\n" string)
      (setq list (cons (substring string 0
				  (match-beginning 0))
		       list))
      (setq string (substring string (match-end 0) (length string))))
    (cons string (reverse list))))

(defun rmoo-send-kill ()
  "Send the first item on the kill ring to rmoo-worl-here."
  (interactive)
  (rmoo-send-here (car kill-ring)))

(defun rmoo-up-command ()
  "Moves point back to the input line and scrolls through history."
  (interactive)
  (goto-char (point-max))
  (rmoo-previous-command))

(defun rmoo-down-command ()
  "Moves point back to the input line and scrolls through history."
  (interactive)
  (goto-char (point-max))
  (rmoo-next-command))

(defun rmoo-clear-input ()
  "Jump to the input line and delete whatever is there."
  (interactive)
  (if (and (bound-and-true-p evil-mode) (eq evil-state 'normal))
    (evil-insert-state nil))
  (goto-char (point-max))
  (rmoo-beginning-of-line)
  (if (= scroll-step 1)
      (recenter -1))
  (delete-region (point) (progn (forward-line 1) (point))))

(defun rmoo-quit ()
  "Quit MOO process."
  (interactive)
  (if (yes-or-no-p "Are you sure you want to quit this MOO session? ")
      (progn
	(delete-process (get-buffer-process (current-buffer)))
	(put rmoo-world-here 'process nil)
	(message (substitute-command-keys (concat "Disconnected.  "
         "Press \\[kill-buffer] to kill this buffer."))))))

(defmacro rmoo-match-string (n str)
  (list 'substring str (list 'match-beginning n) (list 'match-end n)))

(defun rmoo-retarget (world)
  (interactive (list (rmoo-request-world)))
  (if (eq (string-match "^\\(.*@\\)\\(.*\\)" mode-name) 0)
      (setq mode-name (concat (substring mode-name (match-beginning 1)
					 (match-end 1))
			      (symbol-name world))))
  (setq rmoo-world-here world))

(defun rmoo-upload-buffer-directly ()
  (interactive)
  (if (boundp 'rmoo-mcp-data)
    (save-excursion
    (rmoo-send-here (concat "#$#dns-org-mud-moo-simpleedit-set " (cdr (assoc "auth-key" rmoo-mcp-data)) " " (cdr (assoc "reference" rmoo-mcp-data))))
    (goto-char (point-min))
    (while (not (eobp))
           (rmoo-send-here (concat "#$#* " (cdr (assoc "_data-tag" rmoo-mcp-data)) " content: " (buffer-substring-no-properties (point) (line-end-position))))
           (forward-line 1))
    (rmoo-send-here (concat "#$#: " (cdr (assoc "_data-tag" rmoo-mcp-data)))))
  (rmoo-send-here (buffer-string))))

(defun rmoo-append-to-logfile (log-text)
  "Appends text to the log file.\nIf no log file is specifed (nil), nothing happens. That's about the extend of the safety checks, so hopefully the path is valid!"
  (interactive)
  (if rmoo-logfile
  ;; We put a -1 for visit to inhibit the 'Wrote filename' messages entry every time
  (write-region (concat log-text "\n") nil rmoo-logfile 'append 0)))

(add-to-list 'rmoo-handle-text-redirect-functions 'rmoo-append-to-logfile)

(defun rmoo-set-linelength ()
  "Send the size of the window to the @linelength command."
  (interactive)
  (rmoo-send-here (concat "@linelength " (number-to-string (- (window-total-width) 5)))))

;;
;; Thrown in for old times sake..
;;
(defun rmoo-name (world)
  (symbol-name world))

(defun rmoo-destroy ()
  (interactive)
  (kill-buffer (current-buffer))
  (delete-window))

(defun rmoo-upload-and-destroy ()
  (interactive)
  (rmoo-upload-buffer-directly)
  (rmoo-destroy))
