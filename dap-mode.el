;;; dap-mode.el --- Debug Adapter Protocol mode      -*- lexical-binding: t; -*-

;; Copyright (C) 2018  Ivan Yonchovski

;; Author: Ivan Yonchovski <yyoncho@gmail.com>
;; Keywords: languages, debug

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:
;; Author: Ivan <kyoncho@myoncho>
;; URL: https://github.com/yyoncho/dap-mode
;; Package-Requires: ((Emacs "25.1"))
;; Version: 0.1

;; Debug Adapter Protocol

;;; Code:

(require 'lsp-mode)
(require 'json)
(require 'f)
(require 'dash)
(require 'dap-overlays)

(defconst dap--breakpoints-file ".breakpoints"
  "Name of the file in which the breakpoints will be persisted.")

(defconst dap--debug-configurations-file ".debug-configurations.el"
  "Name of the file in which the breakpoints will be persisted.")

(defcustom dap-print-io t
  "If non-nil, print all messages to and from the DAP to messages."
  :group 'dap-mode
  :type 'boolean)

(defcustom dap-run-configurations-file (locate-user-emacs-file "dap-configurations.el" )
  "The file in which the run configurations will be stored by default."
  :group 'dap-mode
  :type 'boolean)

(defcustom dap-terminated-hook nil
  "List of functions to be called after a debug session has been terminated.

The functions will received the debug dession that
has been terminated."
  :type 'hook
  :group 'dap-mode)

(defcustom dap-stopped-hook nil
  "List of functions to be called after a breakpoint has been hit."
  :type 'hook
  :group 'dap-mode)

(defcustom dap-session-changed-hook nil
  "List of functions to be called after sessions have changed."
  :type 'hook
  :group 'dap-mode)

(defcustom dap-continue-hook nil
  "List of functions to be called after application started.

The hook is called after application has been stopped/started(e.
g. after calling `dap-continue')"
  :type 'hook
  :group 'dap-mode)

(defcustom dap-executed-hook nil
  "List of functions that will be called after execution and processing request."
  :type 'hook
  :group 'dap-mode)

(defcustom dap-breakpoints-changed-hook nil
  "List of functions that will be called after breakpoints have changed.
The hook will be called with the session file and the new set of breakpoint locations."
  :type 'hook
  :group 'dap-mode)

(defcustom dap-position-changed-hook nil
  "List of functions that will be called after cursor position has changed."
  :type 'hook
  :group 'dap-mode)

(defcustom dap-stack-frame-changed-hook nil
  "List of functions that will be called after active stack frame has changed."
  :type 'hook
  :group 'dap-mode)

(defvar dap--debug-providers (make-hash-table :test 'equal))

(defvar dap--debug-template-configurations ()
  "Plist Template configurations for DEBUG/RUN.")

(defvar dap--debug-configuration ()
  "List of the previous configuration that have been executed.")

(defun dap--cur-session ()
  "Get currently active `dap--debug-session'."
  (when lsp--cur-workspace
    (lsp-workspace-get-metadata "default-session" lsp--cur-workspace)))

(defun dap--resp-handler (&optional success-callback)
  "Generate response handler.

The handler will call `error' on failure.
SUCCESS-CALLBACK will be called if it is provided and if the call
has succeeded."
  (-lambda ((result &as &hash "success" success "message" msg))
    (if success
        (when success-callback (funcall  success-callback result))
      (error msg))))

(defun dap--cur-session-or-die ()
  "Get currently selection `dap--debug-session' or die."
  (or (dap--cur-session) (error "No active current session")))

(defun dap--session-running (debug-session)
  "Check whether DEBUG-SESSION still running."
  (and debug-session (not (eq 'terminated (dap--debug-session-state debug-session)))))

(defun dap--cur-active-session-or-die ()
  "Get currently non-terminated  `dap--debug-session' or die."
  (-let ((debug-session (dap--cur-session-or-die)))
    (if (dap--session-running debug-session)
        debug-session
      (error "Session %s is terminated" (dap--debug-session-name debug-session)))))

(defun dap-breakpoint-get-point (breakpoint)
  "Get position of BREAKPOINT."
  (or (-some-> breakpoint (plist-get :marker) marker-position)
      (plist-get breakpoint :point)))

(defun dap--set-cur-session (debug-session)
  "Change the active debug session to DEBUG-SESSION."
  (lsp-workspace-set-metadata "default-session" debug-session lsp--cur-workspace))

(defmacro dap--put-if-absent (config key form)
  "Update KEY to FORM if KEY does not exist in plist CONFIG."
  `(plist-put ,config ,key (or (plist-get ,config ,key) ,form)))

(defun dap--locate-workspace-file (workspace file-name)
  "Locate FILE-NAME with relatively to WORKSPACE root dir."
  (f-join (lsp--workspace-root workspace) file-name))

(defun dap--completing-read (prompt collection transform-fn &optional predicate
                                  require-match initial-input
                                  hist def inherit-input-method)
  "Wrap `completing-read' to provide tranformation function.

TRANSFORM-FN will be used to transform each of the items before displaying.

PROMPT COLLECTION PREDICATE REQUIRE-MATCH INITIAL-INPUT HIST DEF
INHERIT-INPUT-METHOD will be proxied to `completing-read' without changes."
  (let* ((result (--map (cons (funcall transform-fn it) it) collection))
         (completion (completing-read prompt (-map 'first result)
                                      predicate require-match initial-input hist
                                      def inherit-input-method)))
    (cdr (assoc completion result))))

(defun dap--plist-delete (plist property)
  "Delete PROPERTY from PLIST.
This is in contrast to merely setting it to 0."
  (let (p)
    (while plist
      (if (not (eq property (first plist)))
          (setq p (plist-put p (first plist) (nth 1 plist))))
      (setq plist (cddr plist)))
    p))

(defun dap--json-encode (params)
  "Create a LSP message from PARAMS, after encoding it to a JSON string."
  (let* ((json-encoding-pretty-print dap-print-io)
         (json-false :json-false))
    (json-encode params)))

(defun dap--make-message (params)
  "Create a LSP message from PARAMS, after encoding it to a JSON string."
  (let* ((body (dap--json-encode params)))
    (format "Content-Length: %d\r\n\r\n%s" (string-bytes body) body)))

(cl-defstruct dap--debug-session
  (name nil)
  ;; ‘last-id’ is the last JSON-RPC identifier used.
  (last-id 0)

  (proc nil :read-only t)
  ;; ‘response-handlers’ is a hash table mapping integral JSON-RPC request
  ;; identifiers for pending asynchronous requests to functions handling the
  ;; respective responses.  Upon receiving a response from the language server,
  ;; ‘dap-mode’ will call the associated response handler function with a
  ;; single argument, the deserialized response parameters.
  (response-handlers (make-hash-table :test 'eql) :read-only t)

  ;; DAP parser.
  (parser (make-dap--parser) :read-only t)
  (output-buffer (generate-new-buffer "*out*"))
  (thread-id nil)
  (workspace nil)
  (threads nil)
  (thread-states (make-hash-table :test 'eql) :read-only t)

  (active-frame-id nil)
  (active-frame nil)
  (cursor-marker nil)
  ;; The session breakpoints;
  (session-breakpoints (make-hash-table :test 'equal) :read-only t)
  ;; one of 'started
  (state 'pending)
  (breakpoints (make-hash-table :test 'equal) :read-only t)
  (thread-stack-frames (make-hash-table :test 'eql) :read-only t)
  (launch-args nil))

(cl-defstruct dap--parser
  (waiting-for-response nil)
  (response-result nil)

  ;; alist of headers
  (headers '())

  ;; message body
  (body nil)

  ;; If non-nil, reading body
  (reading-body nil)

  ;; length of current message body
  (body-length nil)

  ;; amount of current message body currently stored in 'body'
  (body-received 0)

  ;; Leftover data from previous chunk; to be processed
  (leftovers nil))

(defun dap--parse-header (s)
  "Parse string S as a DAP (KEY . VAL) header."
  (let ((pos (string-match "\:" s))
        key val)
    (unless pos
      (signal 'lsp-invalid-header-name (list s)))
    (setq key (substring s 0 pos)
          val (substring s (+ 2 pos)))
    (when (string-equal key "Content-Length")
      (cl-assert (cl-loop for c being the elements of val
                          when (or (> c ?9) (< c ?0)) return nil
                          finally return t)
                 nil (format "Invalid Content-Length value: %s" val)))
    (cons key val)))

(defun dap--get-breakpoints (workspace)
  "Get breakpoints in WORKSPACE."
  (or (lsp-workspace-get-metadata "Breakpoints" workspace)
      (let ((it (make-hash-table :test 'equal)))
        (lsp-workspace-set-metadata "Breakpoints" it)
        it)))

(defun dap--persist (workspace file-name to-persist)
  "Persist TO-PERSIST.

FILE-NAME the file name.
WORKSPACE will be used to calculate root folder."
  (with-demoted-errors
      "Failed to persist file: %S"
    (with-temp-file (dap--locate-workspace-file workspace file-name)
      (erase-buffer)
      (insert (prin1-to-string to-persist)))))

(defun dap--get-sessions (workspace)
  "Get sessions for WORKSPACE."
  (lsp-workspace-get-metadata "debug-sessions" workspace))

(defun dap--set-sessions (workspace debug-sessions)
  "Update list of debug sessions for WORKSPACE to DEBUG-SESSIONS."
  (lsp-workspace-set-metadata "debug-sessions" debug-sessions workspace)
  (run-hook-with-args 'dap-session-changed-hook workspace))

(defun dap-toggle-breakpoint ()
  "Toggle breakpoint on the current line."
  (interactive)
  (lsp--cur-workspace-check)
  (let* ((file-name (buffer-file-name))
         (breakpoints (dap--get-breakpoints lsp--cur-workspace))
         (file-breakpoints (gethash file-name breakpoints))
         (updated-file-breakpoints (if-let (existing-breakpoint
                                            (cl-find-if
                                             (lambda (existing)
                                               (= (line-number-at-pos (plist-get existing :marker))
                                                  (line-number-at-pos (point))))
                                             file-breakpoints))
                                       ;; delete if already exists
                                       (progn
                                         (-some-> existing-breakpoint
                                                  (plist-get :marker)
                                                  (set-marker nil))
                                         (cl-remove existing-breakpoint file-breakpoints))
                                     ;; add if does not exist
                                     (push (list :marker (point-marker)
                                                 :point (point))
                                           file-breakpoints))))
    ;; update the list
    (if updated-file-breakpoints
        (puthash file-name updated-file-breakpoints breakpoints)
      (remhash file-name breakpoints))

    ;; do not update the breakpoints represenations if there is active session.
    (when (not (and (dap--cur-session) (dap--session-running (dap--cur-session))))
      (run-hooks 'dap-breakpoints-changed-hook))

    ;; Update all of the active sessions with the list of breakpoints.
    (let ((set-breakpoints-req (dap--set-breakpoints-request
                                file-name
                                updated-file-breakpoints)))
      (->> lsp--cur-workspace
           dap--get-sessions
           (-filter 'dap--session-running)
           (--map (dap--send-message set-breakpoints-req
                                   (dap--resp-handler
                                    (lambda (resp)
                                      (dap--update-breakpoints it
                                                             resp
                                                             file-name)))
                                   it))))
    ;; filter markers before persisting the breakpoints (markers are not writeable)
    (-let [filtered-breakpoints (make-hash-table :test 'equal)]
      (maphash (lambda (k v)
                 (puthash k (--map (dap--plist-delete it :marker) v) filtered-breakpoints))
               breakpoints)
      (dap--persist lsp--cur-workspace dap--breakpoints-file filtered-breakpoints))))

(defun dap--get-body-length (headers)
  "Get body length from HEADERS."
  (let ((content-length (cdr (assoc "Content-Length" headers))))
    (if content-length
        (string-to-number content-length)

      ;; This usually means either the server our our parser is
      ;; screwed up with a previous Content-Length
      (error "No Content-Length header"))))

(defun dap--parser-reset (p)
  "Reset `dap--parser' P."
  (setf
   (dap--parser-leftovers p) ""
   (dap--parser-body-length p) nil
   (dap--parser-body-received p) nil
   (dap--parser-headers p) '()
   (dap--parser-body p) nil
   (dap--parser-reading-body p) nil))

(defun dap--parser-read (p output)
  "Parser OUTPUT using parser P."
  (let ((messages '())
        (chunk (concat (dap--parser-leftovers p) output)))
    (while (not (string-empty-p chunk))
      (if (not (dap--parser-reading-body p))
          ;; Read headers
          (let* ((body-sep-pos (string-match-p "\r\n\r\n" chunk)))
            (if body-sep-pos
                ;; We've got all the headers, handle them all at once:
                (let* ((header-raw (substring chunk 0 body-sep-pos))
                       (content (substring chunk (+ body-sep-pos 4)))
                       (headers
                        (mapcar 'dap--parse-header
                                (split-string header-raw "\r\n")))
                       (body-length (dap--get-body-length headers)))
                  (setf
                   (dap--parser-headers p) headers
                   (dap--parser-reading-body p) t
                   (dap--parser-body-length p) body-length
                   (dap--parser-body-received p) 0
                   (dap--parser-body p) (make-string body-length ?\0)
                   (dap--parser-leftovers p) nil)
                  (setq chunk content))

              ;; Haven't found the end of the headers yet. Save everything
              ;; for when the next chunk arrives and await further input.
              (setf (dap--parser-leftovers p) chunk)
              (setq chunk "")))

        ;; Read body
        (let* ((total-body-length (dap--parser-body-length p))
               (received-body-length (dap--parser-body-received p))
               (chunk-length (string-bytes chunk))
               (left-to-receive (- total-body-length received-body-length))
               (this-body (substring chunk 0 (min left-to-receive chunk-length)))
               (leftovers (substring chunk (string-bytes this-body))))
          (store-substring (dap--parser-body p) received-body-length this-body)
          (setf (dap--parser-body-received p) (+ (dap--parser-body-received p)
                                               (string-bytes this-body)))
          (when (>= chunk-length left-to-receive)
            (push (decode-coding-string (dap--parser-body p) 'utf-8) messages)
            (dap--parser-reset p))

          (setq chunk leftovers))))
    (nreverse messages)))

(defun dap--read-json (str)
  "Read the JSON object contained in STR and return it."
  (let* ((json-array-type 'list)
         (json-object-type 'hash-table)
         (json-false nil))
    (json-read-from-string str)))

(defun dap--resume-application (debug-session)
  "Resume DEBUG-SESSION."
  (-let [thread-id (dap--debug-session-thread-id debug-session)]
    (puthash thread-id "running" (dap--debug-session-thread-states debug-session))
    (puthash thread-id nil (dap--debug-session-thread-stack-frames debug-session)))
  (setf (dap--debug-session-active-frame debug-session) nil)
  (setf (dap--debug-session-thread-id debug-session) nil)
  (run-hook-with-args 'dap-continue-hook debug-session))

;;;###autoload
(defun dap-continue ()
  "Call continue for the currently active session and thread."
  (interactive)
  (let ((debug-session (dap--cur-active-session-or-die)))
    (dap--send-message (dap--make-request "continue"
                                      (list :threadId (dap--debug-session-thread-id debug-session)))
                     (dap--resp-handler)
                     debug-session)
    (dap--resume-application debug-session)))

;;;###autoload
(defun dap-disconnect ()
  "Disconnect from the currently active session."
  (interactive)
  (dap--send-message (dap--make-request "disconnect"
                                    (list :restart :json-false))
                   (dap--resp-handler)
                   (dap--cur-active-session-or-die))
  (dap--resume-application (dap--cur-active-session-or-die)))

;;;###autoload
(defun dap-next ()
  "Debug next."
  (interactive)
  (dap--send-message (dap--make-request
                    "next"
                    (list :threadId (dap--debug-session-thread-id (dap--cur-session))))
                   (dap--resp-handler)
                   (dap--cur-active-session-or-die))
  (dap--resume-application (dap--cur-session)))

;;;###autoload
(defun dap-step-in ()
  "Debug step in."
  (interactive)
  (dap--send-message (dap--make-request
                    "stepIn"
                    (list :threadId (dap--debug-session-thread-id (dap--cur-session))))
                   (dap--resp-handler)
                   (dap--cur-active-session-or-die))
  (dap--resume-application (dap--cur-active-session-or-die)))

;;;###autoload
(defun dap-step-out ()
  "Debug step in."
  (interactive)
  (dap--send-message (dap--make-request
                    "stepOut"
                    (list :threadId (dap--debug-session-thread-id (dap--cur-session))))
                   (dap--resp-handler)
                   (dap--cur-active-session-or-die))
  (dap--resume-application (dap--cur-active-session-or-die)))

(defun dap--go-to-stack-frame (debug-session stack-frame)
  "Make STACK-FRAME the active STACK-FRAME of DEBUG-SESSION."
  (let ((lsp--cur-workspace (dap--debug-session-workspace debug-session)))
    (when stack-frame
      (-let (((&hash "line" line "column" column "name" name) stack-frame)
             (source (gethash "source" stack-frame)))
        (if source
            (progn (find-file (lsp--uri-to-path (gethash "path" source)))
                   (setf (dap--debug-session-active-frame debug-session) stack-frame)

                   (goto-char (point-min))
                   (forward-line (1- (gethash "line" stack-frame)))
                   (forward-char (gethash "column" stack-frame)))
          (message "No source code for %s. Cursor at %s:%s." name line column))))
    (run-hook-with-args 'dap-stack-frame-changed-hook debug-session)))

(defun dap--select-thread-id (debug-session thread-id)
  "Make the thread with id=THREAD-ID the active thread for DEBUG-SESSION."
  ;; make the thread the active session only if there is no active debug
  ;; session.
  (when (not (dap--debug-session-thread-id debug-session))
    (setf (dap--debug-session-thread-id debug-session) thread-id))

  (dap--send-message
   (dap--make-request "stackTrace" (list :threadId thread-id))
   (dap--resp-handler
    (-lambda ((&hash "body" (&hash "stackFrames" stack-frames)))
      (puthash thread-id
               stack-frames
               (dap--debug-session-thread-stack-frames debug-session))
      (when (eq debug-session (dap--cur-session))
        (dap--go-to-stack-frame debug-session (first stack-frames)))))
   debug-session)
  (run-hook-with-args 'dap-stopped-hook debug-session))

(defun dap--refresh-breakpoints (debug-session)
  "Refresh breakpoints for DEBUG-SESSION."
  (->> debug-session
       dap--debug-session-workspace
       lsp--workspace-buffers
       (--map (with-current-buffer it
                (dap--set-breakpoints-in-file
                 buffer-file-name
                 (->> lsp--cur-workspace dap--get-breakpoints (gethash buffer-file-name)))))))

(defun dap--on-event (debug-session event)
  "Dispatch EVENT for DEBUG-SESSION."
  (let ((event-type (gethash "event" event)))
    (pcase event-type
      ("output" (with-current-buffer (dap--debug-session-output-buffer debug-session)
                  (save-excursion
                    (goto-char (point-max))
                    (insert (gethash "output" (gethash "body" event))))))
      ("breakpoint" ())
      ("thread" (-let [(&hash "body" (&hash "threadId" id "reason" reason)) event]
                  (puthash id reason (dap--debug-session-thread-states debug-session))
                  (run-hooks 'dap-session-changed-hook)
                  (dap--send-message
                   (dap--make-request "threads")
                   (-lambda ((&hash "body" body))
                     (setf (dap--debug-session-threads debug-session)
                           (when body (gethash "threads" body)))
                     (run-hooks 'dap-session-changed-hook))
                   debug-session)))
      ("exited" (with-current-buffer (dap--debug-session-output-buffer debug-session)
                  ;; (insert (gethash "body" (gethash "body" event)))
                  ))
      ("stopped"
       (-let [(&hash "body" (&hash "threadId" thread-id "type" reason)) event]
         (puthash thread-id reason (dap--debug-session-thread-states debug-session))
         (dap--select-thread-id debug-session thread-id)))
      ("terminated"
       (setf (dap--debug-session-state debug-session) 'terminated)
       (delete-process (dap--debug-session-proc debug-session))
       (clrhash (dap--debug-session-breakpoints debug-session))
       (dap--refresh-breakpoints debug-session)
       (run-hook-with-args 'dap-terminated-hook debug-session))
      (_ (message (format "No messages handler for %s" event-type))))))

(defun dap--create-filter-function (debug-session)
  "Create filter function for DEBUG-SESSION."
  (let ((parser (dap--debug-session-parser debug-session))
        (handlers (dap--debug-session-response-handlers debug-session)))
    (lambda (_ msg)
      (mapc (lambda (m)
              (let* ((parsed-msg (dap--read-json m))
                     (key (gethash "request_seq" parsed-msg nil)))
                (when dap-print-io
                  (let ((inhibit-message t))
                    (message "Received:\n%s" (dap--json-encode parsed-msg))))
                (pcase (gethash "type" parsed-msg)
                  ("event" (dap--on-event debug-session parsed-msg))
                  ("response" (if-let (callback (gethash key handlers nil))
                                  (progn
                                    (funcall callback parsed-msg)
                                    (remhash key handlers)
                                    (run-hook-with-args 'dap-executed-hook
                                                        debug-session
                                                        (gethash "command" parsed-msg)))
                                (message "Unable to find handler for %s." (pp parsed-msg)))))))
            (dap--parser-read parser msg)))))

(defun dap--make-request (command &optional args)
  "Make request for COMMAND with arguments ARGS."
  (if args
      (list :command command
            :arguments args
            :type "request")
    (list :command command
          :type "request")))

(defun dap--initialize-message (adapter-id)
  "Create initialize message.
ADAPTER-ID the id of the adapter."
  (list :command "initialize"
        :arguments (list :clientID "vscode"
                         :clientName "Visual Studio Code"
                         :adapterID adapter-id
                         :pathFormat "path"
                         :linesStartAt1 t
                         :columnsStartAt1 t
                         :supportsVariableType t
                         :supportsVariablePaging t
                         :supportsRunInTerminalRequest t
                         :locale "en-us")
        :type "request"))

(defun dap--json-pretty-print (msg)
  "Convert json MSG string to pretty printed json string."
  (let ((json-encoding-pretty-print t))
    (json-encode (json-read-from-string msg))))

(defun dap--send-message (message callback debug-session)
  "MESSAGE DEBUG-SESSION CALLBACK."
  (if (dap--session-running debug-session)
      (let* ((request-id (cl-incf (dap--debug-session-last-id debug-session)))
             (message (plist-put message :seq request-id)))
        (puthash request-id callback (dap--debug-session-response-handlers debug-session))
        (when dap-print-io
          (let ((inhibit-message t))
            (message "Sending: \n%s" (dap--json-encode message))))
        (process-send-string (dap--debug-session-proc debug-session)
                             (dap--make-message message)))
    (error "Session %s is already terminated" (dap--debug-session-name debug-session))))

(defun dap--create-session (launch-args)
  "Create debug session from LAUNCH-ARGS."
  (let* ((host (plist-get launch-args :host))
         (port (plist-get launch-args :debugServer))
         (session-name (plist-get launch-args :name))
         (proc (open-network-stream session-name nil host port :type 'plain))
         (debug-session (make-dap--debug-session
                         :launch-args launch-args
                         :proc proc
                         :name (plist-get launch-args :name)
                         :workspace lsp--cur-workspace)))
    (set-process-filter proc (dap--create-filter-function debug-session))
    debug-session))

(defun dap--send-configuration-done (debug-session _)
  "Send 'configurationDone' message for DEBUG-SESSION."
  (dap--send-message (dap--make-request "configurationDone")
                   (dap--resp-handler
                    (lambda (_)
                      (setf (dap--debug-session-state debug-session) 'running)
                      (run-hook-with-args 'dap-session-changed-hook)))
                   debug-session))

(defun dap--set-breakpoints-request (file-name file-breakpoints)
  "Make `setBreakpoints' request for FILE-NAME.
FILE-BREAKPOINTS is a list of the breakpoints to set for FILE-NAME."
  (with-temp-buffer
    (insert-file-contents-literally file-name)
    (dap--make-request "setBreakpoints"
                     (list :source (list :name (f-filename file-name)
                                         :path file-name)
                           :breakpoints (->> file-breakpoints
                                             (--map (->> it
                                                         dap-breakpoint-get-point
                                                         line-number-at-pos
                                                         (list :line)))
                                             (apply 'vector))
                           :sourceModified :json-false))))

(defun dap--update-breakpoints (debug-session resp file-name)
  "Update breakpoints in FILE-NAME.

RESP is the result from the `setBreakpoints' request.
DEBUG-SESSION is the active debug session."
  (-if-let (server-breakpoints (gethash "breakpoints" (gethash "body" resp)))
      (->> debug-session dap--debug-session-breakpoints (puthash file-name server-breakpoints))
    (->> debug-session dap--debug-session-breakpoints (remhash file-name)))

  (when (eq debug-session (dap--cur-session))
    (-when-let (buffer (find-buffer-visiting file-name))
      (with-current-buffer buffer
        (run-hooks 'dap-breakpoints-changed-hook)))))

(defun dap--configure-breakpoints (debug-session breakpoints callback result)
  "Configure breakpoints for DEBUG-SESSION.

BREAKPOINTS is the list of breakpoints to set.
CALLBACK will be called once configure is finished.
RESULT to use for the callback."
  (let ((breakpoint-count (hash-table-count breakpoints))
        (finished 0))
    (if (zerop breakpoint-count)
        ;; no breakpoints to set
        (funcall callback result)
      (maphash
       (lambda (file-name file-breakpoints)
         (dap--send-message
          (dap--set-breakpoints-request file-name file-breakpoints)
          (dap--resp-handler
           (lambda (resp)
             (setf finished (1+ finished))
             (dap--update-breakpoints debug-session resp file-name)
             (when (= finished breakpoint-count) (funcall callback result))))
          debug-session))
       breakpoints))))

(defun dap-eval (expression)
  "Eval and print EXPRESSION."
  (interactive "sEval: ")
  (let ((debug-session (dap--cur-active-session-or-die)))

    (if-let ((active-frame-id (-some->> debug-session
                                        dap--debug-session-active-frame
                                        (gethash "id"))))
        (dap--send-message (dap--make-request
                          "evaluate"
                          (list :expression expression
                                :frameId active-frame-id))
                         (lambda (result)
                           (-let [msg (if (gethash "success" result)
                                          (gethash "result" (gethash "body" result))
                                        (gethash "message" result))]
                             (message msg)
                             (dap--display-interactive-eval-result msg (point))))
                         debug-session)
      (error "There is no stopped debug session"))))

(defun dap-eval-thing-at-point ()
  "Eval and print EXPRESSION."
  (interactive)
  (dap-eval (thing-at-point 'symbol)))

(defun dap-eval-region (start end)
  "Evaluate the region between START and END."
  (interactive "r")
  (dap-eval (buffer-substring-no-properties start end)))

(defun dap-switch-stack-frame ()
  "Switch stackframe by selecting another stackframe stackframes from current thread."
  (interactive)
  (when (not (dap--cur-session))
    (error "There is no active session"))

  (-if-let (thread-id (dap--debug-session-thread-id (dap--cur-session)))
      (-if-let (stack-frames (gethash thread-id
                                      (dap--debug-session-thread-stack-frames (dap--cur-session))))
          (let ((new-stack-frame (dap--completing-read "Select active frame: "
                                                     stack-frames
                                                     (lambda (it) (gethash "name" it))
                                                     nil
                                                     t)))
            (dap--go-to-stack-frame (dap--cur-session) new-stack-frame))
        (->> (dap--cur-session)
             dap--debug-session-name
             (format "Current session %s is not stopped")
             error))
    (error "No thread is currently active %s" (dap--debug-session-name (dap--cur-session)))))

(defun dap--calculate-unique-name (debug-session-name debug-sessions)
  "Calculate unique name with prefix DEBUG-SESSION-NAME.
DEBUG-SESSIONS - list of the currently active sessions."
  (let ((session-name debug-session-name)
        (counter 1))
    (while (--first (string= session-name (dap--debug-session-name it)) debug-sessions)
      (setq session-name (format "%s<%s>" debug-session-name counter))
      (setq counter (1+ counter)))
    session-name))

(defun dap-start-debugging (launch-args)
  "Start debug session with LAUNCH-ARGS."
  (let ((debug-session (dap--create-session launch-args))
        (workspace lsp--cur-workspace)
        (breakpoints (dap--get-breakpoints lsp--cur-workspace)))
    (dap--send-message
     (dap--initialize-message (plist-get launch-args :type))
     (dap--resp-handler
      (lambda (initialize-result)
        (-let [debug-sessions (dap--get-sessions workspace)]

          ;; update session name accordingly
          (setf (dap--debug-session-name debug-session)
                (dap--calculate-unique-name (dap--debug-session-name debug-session)
                                          debug-sessions))

          (dap--set-sessions workspace (cons debug-session debug-sessions)))
        (dap--send-message
         (dap--make-request (plist-get launch-args :request) launch-args)
         (apply-partially #'dap--configure-breakpoints
                          debug-session
                          breakpoints
                          (apply-partially #'dap--send-configuration-done
                                           debug-session))
         debug-session)))
     debug-session)
    (dap--set-cur-session debug-session)
    (push (cons (plist-get launch-args :name) launch-args) dap--debug-configuration)))

(defun dap--set-breakpoints-in-file (file file-breakpoints)
  "Establish markers for FILE-BREAKPOINTS in FILE."
  (-when-let (buffer (get-file-buffer file))
    (with-current-buffer buffer
      (mapc (lambda (bkp)
              (-let [marker (make-marker)]
                (set-marker marker (plist-get bkp :point))
                (plist-put bkp :marker marker)))
            file-breakpoints)
      (run-hooks 'dap-breakpoints-changed-hook))))

;; load persisted debug configurations.
(defun dap--debug-configurations ()
  "Gets the stored configurations."
  (dap--read-from-file
   (dap--locate-workspace-file
    lsp--cur-workspace
    dap--debug-configurations-file)))

(defun dap--read-from-file (file)
  "Read FILE content."
  (with-temp-buffer
    (insert-file-contents-literally file)
    (first (read-from-string
            (buffer-substring-no-properties (point-min) (point-max))))))

(defun dap--after-initialize ()
  "After initialize handler."
  (with-demoted-errors
      "Failed to load breakpoints for the current workspace with error: %S"
    (let ((breakpoints-file (dap--locate-workspace-file lsp--cur-workspace
                                                      dap--breakpoints-file))
          (workspace lsp--cur-workspace))
      (when (f-exists? breakpoints-file)
        (-let [breakpoints (dap--read-from-file breakpoints-file)]
          (maphash (lambda (file file-breakpoints)
                     (dap--set-breakpoints-in-file file file-breakpoints))
                   breakpoints)
          (lsp-workspace-set-metadata "Breakpoints"
                                     breakpoints
                                     workspace))))))

(defun dap-mode-line ()
  "Calculate DAP modeline."
  (-when-let (debug-session (dap--cur-session))
    (format "%s - %s|"
            (dap--debug-session-name debug-session)
            (dap--debug-session-state debug-session))))

(defun dap--thread-label (debug-session thread)
  "Calculate thread name for THREAD from DEBUG-SESSION."
  (let ((thread-id (gethash "id" thread))
        (name (gethash "name" thread)))
    (-if-let (status (gethash
                      thread-id
                      (dap--debug-session-thread-states debug-session)))
        (format "%s (%s)" name status)
      name)))

(defun dap-switch-thread ()
  "Switch current thread."
  (interactive)
  (let ((debug-session (dap--cur-active-session-or-die)))
    (dap--send-message
     (dap--make-request "threads")
     (-lambda ((&hash "body" (&hash "threads" threads)))
       (setf (dap--debug-session-threads debug-session) threads)
       (-let [(&hash "id" thread-id) (dap--completing-read
                                      "Select active thread: "
                                      threads
                                      (apply-partially 'dap--thread-label debug-session))]
         (dap--select-thread-id debug-session thread-id)))
     debug-session)))

(defun dap-stop-thread ()
  "Stop selected thread."
  (interactive)
  (let ((debug-session (dap--cur-active-session-or-die)))
    (dap--send-message
     (dap--make-request "threads")
     (-lambda ((&hash "body" (&hash "threads" threads)))
       (setf (dap--debug-session-threads debug-session) threads)
       (-let [(&hash "id" thread-id) (dap--completing-read
                                      "Select active thread: "
                                      threads
                                      (apply-partially 'gethash "name"))]
         (dap--send-message
          (dap--make-request
           "pause"
           (list :threadId thread-id))
          (dap--resp-handler)
          debug-session)))
     debug-session)))

(defun dap--switch-to-session (new-session)
  "Make NEW-SESSION the active debug session."
  (dap--set-cur-session new-session)

  (->> new-session
       dap--debug-session-workspace
       lsp--workspace-buffers
       (--map (with-current-buffer it
                (dap--set-breakpoints-in-file
                 buffer-file-name
                 (->> lsp--cur-workspace dap--get-breakpoints (gethash buffer-file-name))))))

  (run-hook-with-args 'dap-session-changed-hook lsp--cur-workspace)

  (-some->> new-session
            dap--debug-session-active-frame
            (dap--go-to-stack-frame new-session)))

(defun dap-switch-session ()
  "Switch current session interactively."
  (interactive)
  (lsp--cur-workspace-check)
  (let* ((current-session (dap--cur-session))
         (target-debug-sessions (reverse
                                 (--remove
                                  (or (not (dap--session-running it))
                                      (eq it current-session))
                                  (dap--get-sessions lsp--cur-workspace)))))
    (case (length target-debug-sessions)
      (0 (error "No active session to switch to"))
      (1 (dap--switch-to-session (first target-debug-sessions)))
      (t (dap--switch-to-session
          (dap--completing-read "Select session: "
                              target-debug-sessions
                              'dap--debug-session-name))))))

(defun dap-register-debug-provider (language-id provide-configuration-fn)
  "Register debug configuration provider for LANGUAGE-ID.

PROVIDE-CONFIGURATION-FN is a function which will be called when
`dap-mode' has received a request to start debug session which
has language id = LANGUAGE-ID. The function must return debug
arguments which contain the debug port to use for opening TCP connection."
  (puthash language-id provide-configuration-fn dap--debug-providers))

(defun dap-register-debug-template (configuration-name configuration-settings)
  "Register configuration template CONFIGURATION-NAME.

CONFIGURATION-SETTINGS - plist containing the preset settings for the configuration."
  (add-to-list
   'dap--debug-template-configurations
   (cons configuration-name configuration-settings)))

(defun dap--select-template ()
  "Select the configuration to launch."
  (copy-tree (rest (dap--completing-read "Select configuration template:"
                                       dap--debug-template-configurations
                                       'first nil t))))

(defun dap-debug (launch-args)
  "Run debug configuration LAUNCH-ARGS.

If LAUNCH-ARGS is not specified the configuration is generated
after selecting configuration template."
  (interactive (list (dap--select-template)))
  (let ((language-id (plist-get launch-args :type)))
    (if-let ((debug-provider (gethash language-id dap--debug-providers)))
        (dap-start-debugging (funcall debug-provider launch-args))
      (error "There is no debug provider for language %s" (or language-id "'Not specified'")))))

(defun dap-debug-create-runner ()
  "Create runner from template."
  (interactive)
  (let* ((launch-args (dap--select-template))
         (buf (generate-new-buffer "*run-configuration*.el")))
    (with-current-buffer buf
      (cl-prettyprint `(defun my/run-configuration ()
                         (interactive)
                         (dap-debug (list ,@launch-args)))))
    (pop-to-buffer buf)
    (emacs-lisp-mode)
    (yas-expand-snippet (buffer-string) (point-min) (point-max))))

(defun dap-debug-last ()
  "Debug last configuration."
  (interactive)
  (if-let (configuration (cdr (first dap--debug-configuration)))
      (dap-debug configuration)
    (funcall-interactively 'dap-debug-select-configuration)))

(defun dap-debug-recent ()
  "Debug last configuration."
  (interactive)
  (->> (dap--completing-read "Select configuration: "
                           dap--debug-configuration
                           'first nil t)
       rest
       dap-debug))

(defun dap-go-to-output-buffer ()
  "Go to output buffer."
  (interactive)
  (->> (dap--cur-session-or-die)
       dap--debug-session-output-buffer
       pop-to-buffer))

(defun dap-delete-session (debug-session)
  "Remove DEBUG-SESSION.
If the current session it will be terminated."
  (interactive (list (dap--cur-session-or-die)))
  (let* ((cleanup-fn (lambda ()
                       (->> lsp--cur-workspace
                            dap--get-sessions
                            (-remove-item debug-session)
                            (dap--set-sessions lsp--cur-workspace))
                       (when (eq (dap--cur-session) debug-session)
                         (dap--switch-to-session nil))
                       (-when-let (buffer (dap--debug-session-output-buffer debug-session))
                         (kill-buffer buffer))
                       (message "Session %s deleted." (dap--debug-session-name debug-session)))))
    (if (eq 'terminated (dap--debug-session-state debug-session))
        (funcall cleanup-fn)
      (dap--send-message (dap--make-request "disconnect"
                                        (list :restart :json-false))
                       (dap--resp-handler
                        (lambda (_resp) (funcall cleanup-fn)))
                       debug-session))))

(defun dap-delete-all-sessions ()
  "Terminate/remove all sessions."
  (interactive)
  (->> lsp--cur-workspace
       dap--get-sessions
       (--remove (eq 'terminated (dap--debug-session-state it)))
       (--map (dap--send-message (dap--make-request "disconnect"
                                                (list :restart :json-false))
                               (dap--resp-handler)
                               it)))
  (dap--set-sessions lsp--cur-workspace ())
  (dap--switch-to-session nil))

(defun dap-delete-all-breakpoints ()
  "Delete all breakpoints."
  (interactive))

(define-minor-mode dap-mode
  "Global minor mode for DAP mode."
  :init-value nil
  :group 'dap-mode
  :global t
  :lighter (:eval (dap-mode-line))
  (add-hook 'lsp-after-initialize-hook 'dap--after-initialize))

(defun dap-turn-on-dap-mode ()
  "Turn on `dap-mode'."
  (interactive)
  (dap-mode t))

(provide 'dap-mode)
;;; dap-mode.el ends here
