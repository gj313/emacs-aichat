;;; aichat-bingai.el --- aichat-bingai.el   -*- lexical-binding: t; -*-

;; Filename: aichat-bingai.el
;; Description: aichat-bingai.el
;; Author: xhcoding <xhcoding@foxmail.com>
;; Maintainer: xhcoding <xhcoding@foxmail.com>
;; Copyright (C) 2023, xhcoding, all rights reserved.
;; Created: 2023-03-11 15:12:02
;; Version: 0.1
;; Last-Updated: 2023-03-11 15:12:02
;;           By: xhcoding
;; URL: https://github.com/xhcoding/emacs-aichat
;; Keywords:
;; Compatibility: GNU Emacs 30.0.50
;;
;; Features that might be required by this library:
;;
;;
;;

;;; This file is NOT part of GNU Emacs

;;; License
;;
;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program; see the file COPYING.  If not, write to
;; the Free Software Foundation, Inc., 51 Franklin Street, Fifth
;; Floor, Boston, MA 02110-1301, USA.

;;; Commentary:
;;
;; aichat-bingai.el
;;

;;; Installation:
;;
;; Put aichat-bingai.el to your load-path.
;; The load-path is usually ~/elisp/.
;; It's set in your ~/.emacs like this:
;; (add-to-list 'load-path (expand-file-name "~/elisp"))
;;
;; And the following to your ~/.emacs startup file.
;;
;; (require 'aichat-bingai)
;;
;; No need more.

;;; Customize:
;;
;;
;;
;; All of the above can customize by:
;;      M-x customize-group RET aichat-bingai RET
;;

;;; Change log:
;;
;; 2023/03/11
;;      * First released.
;;

;;; Acknowledgements:
;;
;;
;;

;;; TODO
;;
;;
;;

;;; Require
(require 'websocket)

(require 'aichat-util)

;;; Code:

(defgroup aichat-bingai nil
  "Bing AI in Emacs."
  :group 'aichat
  :prefix "aichat-bingai-")

(defcustom aichat-bingai-cookies-file nil
  "The path of www.bing.com cookies file.

When you set this value, bingai will login to www.bing.com through the cookies in the file."
  :group 'aichat-bingai
  :type 'string)

(defcustom aichat-bingai-conversation-style 'balanced
  "Conversation style."
  :group 'aichat-bingai
  :type '(radio
          (const :tag "More Creative" creative)
          (const :tag "More Balanced" balanced)
          (const :tag "More Precise" precise)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; Internal ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(async-defun aichat-bingai--start-process (program &rest args)
  "Async start process with PROGRAM and ARGS.

Returns stdout on success, otherwise returns nil."
  (condition-case reason
      (car (await (promise:make-process-with-handler (cons program args) nil t)))
    (error nil)))

(async-defun aichat-bingai--shell-command (command &optional dir)
  "Async run COMMAND in DIR or `default-directory'.

Returns stdout on success, otherwise returns nil."
  (condition-case reason
      (let ((default-directory (or dir default-directory)))
        (await (promise:make-shell-command command dir)))
    (error nil)))

(defconst aichat-bingai--domain "bing.com"
  "Bing domain for retrieve cookies.")

(async-defun aichat-bingai--check-deps ()
  "Check if browser_cookie3 is installed."
  (when-let ((installed (await (aichat-bingai--shell-command "python -c \"import browser_cookie3\""))))
    t))

(defun aichat-bingai--get-cookies-from-file (filename)
  "Get `aichat-bingai--domain' cookies from FILENAME."
  (when (file-exists-p filename)
    (let ((cookies (json-read-file filename)))
      (mapcar (lambda (cookie)
                (let ((name (alist-get 'name cookie))
                      (value (alist-get 'value cookie))
                      (expires (if (assq 'expirationDate cookie)
                                   (format-time-string "%FT%T%z"
                                                       (seconds-to-time
                                                        (alist-get 'expirationDate cookie)))
                                 nil))
                      (domain (alist-get 'domain cookie))
                      (localpart (alist-get 'path cookie))
                      (secure (if (eq (alist-get 'secure cookie) :json-false)
                                  nil
                                t)))
                  (list name value expires domain localpart secure)))
              cookies))))

(defconst aichat-bingai--get-cookies-script
  "python -c \"import browser_cookie3;list(map(lambda c: print('{} {} {} {} {} {}'.format(c.name, c.value, c.expires, c.domain, c.path, c.secure)), filter(lambda c: c.domain in ('.bing.com', 'www.bing.com'), browser_cookie3.edge(domain_name='bing.com'))))\""
  "Shell script for get www.bing.com cookies.")

(async-defun aichat-bingai--get-cookies ()
  "Get `aichat-bingai--domain' cookies."
  (await nil)
  (if aichat-bingai-cookies-file
      (aichat-bingai--get-cookies-from-file aichat-bingai-cookies-file)
    (if (not (await (aichat-bingai--check-deps)))
        (message "Please install browser_cookie3 by `pip3 install browser_cookie3`")
      (when-let ((stdout (await
                          (aichat-bingai--shell-command aichat-bingai--get-cookies-script))))
        (mapcar (lambda (line)
                  (let* ((fields (split-string line " " t))
                         (name (nth 0 fields))
                         (value (nth 1 fields))
                         (expires (if (string= (nth 2 fields) "None")
                                      nil
                                    (format-time-string "%FT%T%z" (seconds-to-time (string-to-number (nth 2 fields))))))
                         (domain (nth 3 fields))
                         (localpart (nth 4 fields))
                         (secure (if (string= (nth 5 fields) "1")
                                     t
                                   nil)))
                    (list name value expires domain localpart secure)))
                (split-string stdout "\n" t))))))

(async-defun aichat-bingai--refresh-cookies ()
  "Refresh `aichat-bing--domain' cookies.

Delete all cookies from the cookie store where the domain matches `aichat-bing--domain'.
Re-fetching cookies from `aichat-bing--domain'"
  (when-let ((bing-cookies (await (aichat-bingai--get-cookies))))
    (aichat-debug "bing-cookies:\n%s\n" bing-cookies)
    (ignore-errors (url-cookie-delete-cookies aichat-bingai--domain))
    (dolist (bing-cookie bing-cookies)
      (apply #'url-cookie-store bing-cookie))))

(defun aichat-bingai--login-p ()
  "Check if you're already login."
  (when-let* ((host-cookies
               (seq-find (lambda (host)
                           (string= (car host) ".bing.com"))
                         (append url-cookie-secure-storage)))
              (user (seq-find
                     (lambda (cookie)
                       (string= (aref cookie 1) "_U"))
                     (cdr host-cookies))))
    (and user
         (not (url-cookie-expired-p user)))))

(async-defun aichat-bingai--login ()
  "Login `aichat-bingai--domain'."
  (await t)
  (unless (aichat-bingai--login-p)
    (await (aichat-bingai--refresh-cookies))))

(defconst aichat-bingai--create-conversation-url "https://edgeservices.bing.com/edgesvc/turing/conversation/create"
  "The url of create conversation.")

(defconst aichat-bingai--headers
  `(("accept" . "application/json")
    ("accept-language" . "zh-CN,zh;q=0.9,en;q=0.8,en-GB;q=0.7,en-US;q=0.6")
    ("sec-ch-ua" . "\"Chromium\";v=\"110\", \"Not A(Brand\";v=\"24\", \"Microsoft Edge\";v=\"110\"")
    ("sec-ch-ua-arch" . "\"x86\"")
    ("sec-ch-ua-bitness" . "\"64\"")
    ("sec-ch-ua-full-version" . "\"110.0.1587.57\"")
    ("sec-ch-ua-full-version-list" . "\"Chromium\";v=\"110.0.5481.178\", \"Not A(Brand\";v=\"24.0.0.0\", \"Microsoft Edge\";v=\"110.0.1587.57\"")
    ("sec-ch-ua-mobile" . "?0")
    ("sec-ch-ua-model" . "")
    ("sec-ch-ua-platform" . "\"Windows\"")
    ("sec-ch-ua-platform-version" . "\"15.0.0\"")
    ("sec-fetch-dest" . "empty")
    ("sec-fetch-mode" . "cors")
    ("sec-fetch-site" . "same-origin")
    ("x-ms-client-request-id" . ,(aichat-uuid))
    ("x-ms-useragent" . "azsdk-js-api-client-factory/1.0.0-beta.1 core-rest-pipeline/1.10.0 OS/Win32")
    ("referer" . "https://www.bing.com/search?q=Bing+AI&showconv=1")
    ("referrer-policy" . "origin-when-cross-origin"))
  "The headers of sending request to www.bing.com.")

(cl-defstruct (aichat-bingai--conversation
               (:constructor aichat-bingai--conversation-new)
               (:copier nil))
  "A conversation structure.
`id', `signature' and `client-id' are obtained through the GET request `aichat-bingai--conversation-url' response."
  id
  signature
  client-id)

(async-defun aichat-bingai--create-conversation ()
  "Create a conversation through the GET request `aichat-bingai--conversation-url'."
  (await (aichat-bingai--login))
  (seq-let
      (status headers body)
      (await (aichat-http aichat-bingai--create-conversation-url
                          :headers aichat-bingai--headers))
    (aichat-debug "status:\n%s\nheaders:\n%s\nbody:\n%s\n" status headers body)
    (if (not (string= "200" (car status)))
        (error "Create conversation failed: %s" status)
      (let* ((data (json-read-from-string body))
             (result-value (alist-get 'value (alist-get 'result data))))
        (if (not (string= "Success" result-value))
            (error "Create conversation failed: %s" body)
          (aichat-bingai--conversation-new
           :id (alist-get 'conversationId data)
           :signature (alist-get 'conversationSignature data)
           :client-id (alist-get 'clientId data)))))))

(cl-defstruct (aichat-bingai--session
               (:constructor aichat-bingai--session-new)
               (:copier nil))
  "A session structure.
`conversation' represents the `aichat-bingai--conversation'.
`chathub' represents the chathub websocket connection.
`invocation-id' indicates the number of questions.
`replying' indicates whether the reply is in progress.
`buffer' saves the reply message for parsing.
`resolve' and `reject' are promise callback, call `resolve' when the reply ends
and call `reject' when error occurs.
`result' saves the result of conversation.
Call `user-cb' when a message arrives."
  conversation
  chathub
  (invocation-id 0)
  (replying nil)
  (buffer "")
  resolve
  reject
  result
  user-cb)

(defconst aichat-bingai--message-delimiter (char-to-string #x1e)
  "Websocket json message delimiter.")

(defun aichat-bingai--chathub-parse-message (session text)
  "Parse chathub websocket json message."
  (aichat-debug "Recv text:\n%s" text)
  (let ((buffer (concat (aichat-bingai--session-buffer session) text))
        (start-pos 0)
        (match-pos nil)
        (object))
    (aichat-debug "buffer:\n%s" buffer)
    (catch 'not-find
      (while t
        (setq match-pos (string-match-p aichat-bingai--message-delimiter buffer start-pos))
        (if (not match-pos)
            (throw 'not-find match-pos)
          (setq object (json-read-from-string (substring buffer start-pos match-pos)))
          (aichat-debug "object:\n%s" object)
          (pcase (alist-get 'type object)
            (1 (let ((user-cb (aichat-bingai--session-user-cb session)))
                 (when user-cb
                   (condition-case error
                       (funcall user-cb object)
                     (error
                      (setf (aichat-bingai--session-replying session) nil)
                      (websocket-close (aichat-bingai--session-chathub session))
                      (funcall (aichat-bingai--session-reject session) (format "User callback error: %s\n" error)))))))
            (2 (setf (aichat-bingai--session-result session) object))
            (3 (let ((result (aichat-bingai--session-result session)))
                 (setf (aichat-bingai--session-replying session) nil)   
                 (funcall (aichat-bingai--session-resolve session) result))))
          (setq start-pos (1+ match-pos)))))
    (setf (aichat-bingai--session-buffer session) (substring buffer start-pos))))

(defconst aichat-bingai--chathub-url "wss://sydney.bing.com/sydney/ChatHub"
  "The url of create chathub.")

(defun aichat-bingai--create-chathub (session)
  "Create a websocket connection to `aichat-bingai--chathub-url'.

Call resolve when the handshake with chathub passed."
  (promise-new
   (lambda (resolve reject)
     (websocket-open aichat-bingai--chathub-url
                     :custom-header-alist aichat-bingai--headers
                     :on-open (lambda (ws)
                                (aichat-debug "====== chathub opened ======")
                                ;; send handshake
                                (if (and ws (websocket-openp ws))
                                    (websocket-send-text ws (concat (json-encode
                                                                     (list :protocol "json" :version 1))
                                                                    aichat-bingai--message-delimiter))
                                  (funcall reject "Chathub unexpected closed during handshake.")))
                     :on-close (lambda (_ws)
                                 (aichat-debug "====== chathub closed ======")
                                 (setf (aichat-bingai--session-chathub session) nil)
                                 (when (aichat-bingai--session-replying session)
                                   ;; close when replying
                                   (setf (aichat-bingai--session-replying session) nil)
                                   (funcall (aichat-bingai--session-reject session) "Chathub closed unexpectedly during reply.")))
                     :on-message (lambda (ws frame)
                                   (let ((text (websocket-frame-text frame)))
                                     (condition-case error
                                         (progn
                                           (aichat-debug "Receive handshake response: %s" text)
                                           (json-read-from-string (car (split-string text aichat-bingai--message-delimiter)))
                                           (setf (websocket-on-message ws)
                                                 (lambda (_ws frame)
                                                   (aichat-bingai--chathub-parse-message session (websocket-frame-text frame))))
                                           (setf (aichat-bingai--session-chathub session) ws)
                                           (funcall resolve t))
                                       (error (funcall reject error)))))))))

(defun aichat-bingai--close-chathub (session)
  "Close chathub websocket connection."
  (when-let ((chathub (aichat-bingai--session-chathub session)))
    (when (websocket-openp chathub)
      (websocket-close chathub))))

(defun aichat-bingai--reply-options (style)
  (vector
   "nlu_direct_response_filter"
   "deepleo"
   "disable_emoji_spoken_text"
   "responsible_ai_policy_2235"
   "enablemm"
   "rai253"
   "cricinfo"
   "cricinfov2"
   "dv3sugg"
   (pcase style
     ('creative "h3imaginative")
     ('balanced "harmonyv3")
     ('precise "h3precise"))))

(defconst aichat-bingai--allowed-message-types
  [
   "Chat"
   "InternalSearchQuery"
   "InternalSearchResult"
   "Disengaged"
   "InternalLoaderMessage"
   "RenderCardRequest"
   "AdsQuery"
   "SemanticSerp"
   "GenerateContentQuery"
   ])

(defconst aichat-binai--slice-ids
  [
   "h3adss0"
   "301rai253"
   "225cricinfo"
   "224locals0"
   ])

(defun aichat-bingai--make-request (session text style allowed-message-types)
  (unless allowed-message-types
    (setq allowed-message-types aichat-bingai--allowed-message-types))
  
  (let* ((conversation (aichat-bingai--session-conversation session))
         (invocation-id (aichat-bingai--session-invocation-id session))
         (request (list :arguments
                        (vector
                         (list :source "cib"
                               :optionsSets (aichat-bingai--reply-options style)
                               :allowedMessageTypes allowed-message-types
                               :sliceIds aichat-binai--slice-ids
                               :isStartOfSession (if (= 0 invocation-id)
                                                     t
                                                   :json-false)
                               :message (list :author "user"
                                              :inputMethod "Keyboard"
                                              :text text
                                              :messageType "Chat")
                               :conversationSignature (aichat-bingai--conversation-signature conversation)
                               :participant (list :id (aichat-bingai--conversation-client-id conversation))
                               :conversationId (aichat-bingai--conversation-id conversation)))
                        :invocationId (number-to-string (aichat-bingai--session-invocation-id session))
                        :target "chat"
                        :type 4)))
    (concat (json-encode request)  aichat-bingai--message-delimiter)))

(defvar aichat-bingai--current-session nil  ;; only one session
  "Bingai session.")

(defun aichat-bingai--get-current-session ()
  "Return current session."
  aichat-bingai--current-session)

(defun aichat-bingai--set-current-session (session)
  "Set current session."
  (setq aichat-bingai--current-session session))

(defun aichat-bingai--remove-current-session ()
  "Remove current session."
  (setq aichat-bingai--current-session nil))

(defun aichat-bingai--stop-session ()
  "Stop current bingai session."
  (when-let ((session (aichat-bingai--get-current-session)))
    (setf (aichat-bingai--session-conversation session) nil)
    (aichat-bingai--close-chathub session)
    (aichat-bingai--remove-current-session)))

(async-defun aichat-bingai--start-session ()
  "Start a new aichat-bingai session."
  (await t)
  (aichat-bingai--stop-session)
  (when-let ((conversation (await (aichat-bingai--create-conversation)))
             (session (aichat-bingai--session-new
                       :conversation conversation)))
    (aichat-bingai--set-current-session session)
    t))

(defun aichat-bingai--ensure-conversation-valid ()
  (when-let* ((session (aichat-bingai--get-current-session))
              (invocation-id (aichat-bingai--session-invocation-id session) ))
    (when (> invocation-id 9)
      (aichat-bingai--stop-session))))

(async-defun aichat-bingai--send-request (text style allowed-message-types &optional callback)
  (aichat-bingai--ensure-conversation-valid)
  (let ((session (aichat-bingai--get-current-session)))
    (unless session
      (await (aichat-bingai--start-session))
      (setq session (aichat-bingai--get-current-session)))
    (unless (aichat-bingai--session-chathub session)
      (await (aichat-bingai--create-chathub session)))
    
    (promise-new
     (lambda (resolve reject)
       (let ((request (aichat-bingai--make-request session text style allowed-message-types)))
         (aichat-debug "Send request:\n%s\n" request)
         (websocket-send-text (aichat-bingai--session-chathub session) request)
         (setf (aichat-bingai--session-invocation-id session) (1+ (aichat-bingai--session-invocation-id session))
               (aichat-bingai--session-replying session) t
               (aichat-bingai--session-buffer session) ""
               (aichat-bingai--session-resolve session) resolve
               (aichat-bingai--session-reject session) reject
               (aichat-bingai--session-user-cb session) callback))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; bingai API ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun aichat-bingai-conversationing-p ()
  "Whether conversation or not."
  (when-let ((session (aichat-bingai--get-current-session)))
    (aichat-bingai--session-replying session)))

(defun aichat-bingai-conversation-start-p ()
  "Whether is start of conversation."
  (aichat-bingai--ensure-conversation-valid)
  (not (aichat-bingai--get-current-session)))

(defun aichat-bingai-conversation-reset ()
  "Reset conversation."
  (aichat-bingai--stop-session))

(cl-defun aichat-bingai-conversation (text &rest settings
                                           &key
                                           (style nil)
                                           (allowed-message-types nil)
                                           (on-success nil)
                                           (on-error nil))
  "Send a chat TEXT to Bing.

`style' is the conversation style, look `aichat-bingai-conversation-stye' for detail.
`allowed-message-types' is the message type allowed to return, 
all types in `aichat-bingai--allowed-message-types'."
  (when (aichat-bingai-conversationing-p)
    (error "Please wait for the conversation finished before call."))
  (unless style
    (setq style aichat-bingai-conversation-style))
  (unless allowed-message-types
    (setq allowed-message-types (vector "Chat")))
  
  (promise-then (aichat-bingai--send-request text style allowed-message-types)
                (lambda (result)
                  (when on-success
                    (funcall on-success result)))
                (lambda (err)
                  (when on-error
                    (funcall on-error err)))))


(cl-defun aichat-bingai-conversation-stream (text callback &rest settings
                                                  &key
                                                  (style nil)
                                                  (allowed-message-types nil)
                                                  (on-success nil)
                                                  (on-error nil))
  "Send a chat TEXT to Bing.

`style' is the conversation style, look `aichat-bingai-conversation-stye' for detail.
`allowed-message-types' is the message type allowed to return, 
all types in `aichat-bingai--allowed-message-types'."
  (when (aichat-bingai-conversationing-p)
    (error "Please wait for the conversation finished before call."))
  
  (unless style
    (setq style aichat-bingai-conversation-style))
  
  (unless allowed-message-types
    (setq allowed-message-types (vector "Chat")))
  
  (promise-then (aichat-bingai--send-request text style allowed-message-types 
                                             (lambda (message)
                                               (when callback
                                                 (funcall callback message))))
                (lambda (result)
                  (message "xxxxxxxx: on success: %s" on-success)
                  (when on-success
                    (funcall on-success result)))
                (lambda (err)
                  (when on-error
                    (funcall on-error err)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; Message API ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun aichat-bingai-message-type-1-text (message)
  "message[arguments][0][messages][0][text]."
  (alist-get 'text
             (aref
              (alist-get 'messages
                         (aref (alist-get 'arguments message) 0))
              0)))

(defun aichat-bingai-message-type-1-search-result (message)
  "message[arguments][0][messages][0][hiddenText]."
  (when-let* ((hidden-text (alist-get 'hiddenText
                                      (aref
                                       (alist-get 'messages
                                                  (aref (alist-get 'arguments message) 0))
                                       0)))
              (hidden-object (ignore-errors  (json-read-from-string (string-trim hidden-text "```json" "```")))))
    (cl-loop for result in hidden-object
             vconcat (cdr result))))

(defun aichat-bingai-message-type-1-message-type (message)
  "msg[arguments][0][messages][0][messageType]."
  (alist-get 'messageType
             (aref
              (alist-get 'messages
                         (aref (alist-get 'arguments message) 0))
              0)))

(defun aichat-bingai-message-type-2-search-result (message)
  "message[arguments][0][messages][?][hiddenText]."
  (when-let ((messages (alist-get 'messages (aref (alist-get 'arguments message) 0))))
    (cl-loop for msg across messages
             do (let ((msg-type (alist-get 'messageType msg))
                      (author (alist-get 'author msg)))
                  (when (and (string= msg-type "InternalSearchResult") (string= author "bot"))
                    (when-let* ((hidden-text (alist-get 'hiddenText msg))
                                (hidden-object (ignore-errors (json-read-from-string (string-trim hidden-text "```json" "```")))))
                      (cl-return 
                       (cl-loop for result in hidden-object
                                vconcat (cdr result)))))))))

(defun aichat-bingai-message-type-2-text (message)
  "message[item][messages][?][text]."
  (when-let ((messages (alist-get 'messages (alist-get 'item message))))
    (cl-loop for msg across messages
             do (let ((msg-type (alist-get 'messageType msg))
                      (author (alist-get 'author msg)))
                  (when (and (not msg-type) (string= author "bot"))
                    (cl-return (alist-get 'text msg)))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; Chat ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defcustom aichat-bingai-chat-file (expand-file-name "aichat.md" user-emacs-directory)
  "File path of save chat message."
  :group 'aichat-bingai
  :type 'string)

(defcustom aichat-bingai-chat-display-function 'display-buffer
  "The function of how to display `aichat-bingai-chat-file' buffer."
  :group 'aichat-bingai
  :type 'symbol)

(defface aichat-bingai-chat-prompt-face '((t (:height 0.8 :foreground "#006800")))
  "Face used for prompt overlay.")


(cl-defstruct (aichat-bingai--chat
               (:constructor aichat-bingai--chat-new)
               (:copier nil))
  "A chat structure.
`buffer' is used to display chat message.
`said' is what the user said.
`replied-length' is the length of the reply.
`reply-point' is where the reply is inserted.
`search-results' is the results of web search."
  buffer
  said
  (replied-length 0)
  reply-point
  search-results)

(defun aichat-bingai--chat-get-buffer ()
  "Get chat buffer."
  (let ((chat-buffer (get-file-buffer aichat-bingai-chat-file)))
    (unless chat-buffer
      (setq chat-buffer (find-file-noselect aichat-bingai-chat-file)))
    (with-current-buffer chat-buffer
      (goto-char (point-max))
      (when (derived-mode-p 'markdown-mode)
        (unless markdown-hide-markup
          (markdown-toggle-markup-hiding)))
      (when (and (featurep 'pangu-spacing) pangu-spacing-mode)
        (pangu-spacing-mode -1)))
    chat-buffer))

(defun aichat-bingai--chat-say (chat new-p)
  "Show user said.
NEW-P is t, which means it is a new conversation."
  (with-current-buffer (aichat-bingai--chat-buffer chat)
    (goto-char (point-max))
    (let ((header-char (if (derived-mode-p 'org-mode) "*" "#")))
      (if new-p
          (insert "\n" header-char " ")
        (insert "\n" header-char header-char " ")))
    (insert (aichat-bingai--chat-said chat))
    (insert "\n\n")
    (setf (aichat-bingai--chat-reply-point chat) (point))))

(defun aichat-bingai--chat-update-prompt (chat text)
  (with-current-buffer (aichat-bingai--chat-buffer chat)
    (save-mark-and-excursion
      (goto-char (aichat-bingai--chat-reply-point chat))
      (if (derived-mode-p 'org-mode)
          (org-previous-visible-heading +1)
        (markdown-previous-visible-heading +1))
      (let* ((from (line-beginning-position))
             (to (line-end-position)))
        (remove-overlays from to 'aichat-bingai--chat-handle-reply t)
        (when text
          (let ((ov (make-overlay from to)))
            (overlay-put ov 'after-string
                         (propertize
                          (concat " " text)
                          'face 'aichat-bingai-chat-prompt-face))
            (overlay-put ov 'aichat-bingai--chat-handle-reply t)))))))

(defun aichat-bingai--chat-handle-reply (msg chat)
  (let ((message-type (aichat-bingai-message-type-1-message-type msg))
        (buffer (aichat-bingai--chat-buffer chat)))
    (pcase message-type
      ("InternalSearchQuery" (when-let ((text (aichat-bingai-message-type-1-text msg)))
                               (aichat-bingai--chat-update-prompt chat text)))
      ("InternalLoaderMessage" (when-let ((text (aichat-bingai-message-type-1-text msg)))
                                 (aichat-bingai--chat-update-prompt chat text)))
      ("InternalSearchResult" (when-let ((search-results (aichat-bingai-message-type-1-search-result msg)))
                                (setf (aichat-bingai--chat-search-results chat) search-results)))
      (_
       (when-let* ((text (aichat-bingai-message-type-1-text msg))
                   (replied-length (aichat-bingai--chat-replied-length chat))
                   (text-length (length text))
                   (valid (> text-length replied-length)))
         (with-current-buffer buffer
           (save-mark-and-excursion
             (goto-char (aichat-bingai--chat-reply-point chat))
             (insert (substring text replied-length))
             (setf (aichat-bingai--chat-reply-point chat) (point)
                   (aichat-bingai--chat-replied-length chat) text-length))))))))

(defun aichat-bingai--chat-convert-to-org ()
  (org-previous-visible-heading +1)
  (while (re-search-forward "\\(\\*\\(\\*.*\\*\\)\\*\\|\\[^\\([0-9]+\\)^\\]\\|`\\([^`]+\\)`\\|```\\([a-z]*\\(.\\|\n\\)*\\)```\\)" nil t)
    (when (match-string 2)
      (replace-match "\\2"))
    (when (match-string 3)
      (replace-match "[fn:\\3]"))
    (when (match-string 4)
      (replace-match "=\\4="))
    (when (match-string 5)
      (replace-match "#+begin_src \\5#+end_src"))))

(defun aichat-bingai--chat-handle-reply-finished (chat)
  (message "handle reply finished")
  (condition-case error
      (with-current-buffer (aichat-bingai--chat-buffer chat)
        (save-mark-and-excursion
          (when (derived-mode-p 'org-mode)
            (aichat-bingai--chat-convert-to-org))

          ;; insert search result
          (goto-char (aichat-bingai--chat-reply-point chat))
          (end-of-line)
          (insert "\n")
          (mapc (lambda (result)
                  (aichat-debug "Insert search result: %s"  result)
                  (let ((index (alist-get 'index result))
                        (title (or (alist-get 'title result) 
                                   (alist-get 'Title (alist-get 'data result))))
                        (url (alist-get 'url result)))
                    (insert (format "%s. " index))
                    (if (derived-mode-p 'org-mode)
                        (org-insert-link nil url title)
                      (insert (format "[%s](%s)" title url)))
                    (insert "\n")))
                (aichat-bingai--chat-search-results chat))
          (insert "\n")))
    (error (message "error on finished: %s" error)))
  (aichat-bingai--chat-update-prompt chat nil)
  (message "Finished"))

(defun aichat-bingai--chat-handle-reply-error (chat msg)
  (aichat-bingai--chat-update-prompt chat nil)
  (message "%s" msg))

;;;###autoload
(defun aichat-bingai-chat (said)
  (interactive "sYou say: ")
  (when (and (car current-prefix-arg)
             (= (car current-prefix-arg) 4))
    (aichat-bingai-conversation-reset))
  
  (if (aichat-bingai-conversationing-p)
      (message "Please wait for the conversation finished before saying.")
    (let* ((chat-buffer (aichat-bingai--chat-get-buffer))
           (chat (aichat-bingai--chat-new
                  :buffer chat-buffer
                  :said said)))
      (if (and aichat-bingai-chat-display-function (functionp aichat-bingai-chat-display-function))
          (funcall aichat-bingai-chat-display-function chat-buffer)
        (switch-to-buffer chat-buffer))
      
      (aichat-bingai--chat-say chat (aichat-bingai-conversation-start-p))
      
      (aichat-bingai-conversation-stream said (lambda (msg)
                                                (aichat-bingai--chat-handle-reply msg chat))
                                         :allowed-message-types ["Chat"
                                                                 "InternalSearchQuery"
                                                                 "InternalSearchResult"
                                                                 "InternalLoaderMessage"]
                                         :on-success (lambda (_)
                                                       (aichat-bingai--chat-handle-reply-finished chat))
                                         :on-error (lambda (msg)
                                                     (aichat-bingai--chat-handle-reply-error chat msg))))))

(provide 'aichat-bingai)

;;; aichat-bingai.el ends here