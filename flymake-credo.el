;;; flymake-credo.el --- Flymake backend for Credo -*- lexical-binding: t -*-

;; Author: Vinícius Simões
;; Maintainer: Vinícius Simões
;; Version: 1.0.0
;; Package-Requires: ((emacs "28.1"))
;; Homepage: https://github.com/vinikira/flymake-credo
;; Keywords: languages

;; This file is not part of GNU Emacs

;; The MIT License (MIT)

;; Copyright © 2022 <Vinícius Simões>

;; Permission is hereby granted, free of charge, to any person obtaining
;; a copy of this software and associated documentation files (the
;; “Software”), to deal in the Software without restriction, including
;; without limitation the rights to use, copy, modify, merge, publish,
;; distribute, sublicense, and/or sell copies of the Software, and to
;; permit persons to whom the Software is furnished to do so, subject to
;; the following conditions:

;; The above copyright notice and this permission notice shall be
;; included in all copies or substantial portions of the Software.

;; THE SOFTWARE IS PROVIDED “AS IS”, WITHOUT WARRANTY OF ANY KIND,
;; EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
;; MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
;; IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
;; CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
;; TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
;; SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

;;; Commentary:

;; Provides a utility function to interface with credo, a linting tool for the
;; Elixir programming language.

;; See function `flymake-credo-load'.

;;; Code:

(require 'json)
(require 'project)
(require 'cl-lib)

(defgroup flymake-credo nil
  "Flymake credo functionalites."
  :prefix "flymake-credo-"
  :group 'elixir)

(defcustom flymake-credo-strict t
  "Use credo in a strict mode or not."
  :group 'flymake-credo
  :type 'boolean)

(defcustom flymake-credo-min-priority 0
  "Minimum priority of credo warning to be reported by flymake."
  :group 'flymake-credo
  :type 'integer)

(defcustom flymake-credo-config-file nil
  "Config file to use with credo.

When non-nil, the config file will be passed to the
`--config-file' option of the credo cli"
  :group 'flymake-credo
  :type 'string)

(defcustom flymake-credo-config-name "default"
  "Config name to use with credo.

When non-nil, the config name will be passed to the
`--config-name' option of the credo cli"
  :group 'flymake-credo
  :type 'string)

(defvar-local flymake-credo--proc nil)

(defvar-local flymake-credo--command nil)

(defun flymake-credo (report-fn &rest _args)
  "Credo linter backend for Flymake.
Check for problems, then call REPORT-FN with results."
  (unless (executable-find "mix")
    (error "Cannot find a suitable mix"))

  (setq flymake-credo--command (if (project-current)
                                   '("mix" "credo")
                                 '("credo")))

  (when (and (string= "credo" (car flymake-credo--command))
             (not (executable-find (car flymake-credo--command))))
    (error "Cannot find a suitable credo"))

  (when (process-live-p flymake-credo--proc)
    (kill-process flymake-credo--proc))

  (let* ((project (project-current))
         (buffer-name (format "*flymake-credo for %s* "
                              (if project
                                  (expand-file-name (project-root project))
                                (buffer-name))))
         (stderr-buffer-name (format "*flymake-credo errors for %s* "
                              (if project
                                  (expand-file-name (project-root project))
                                (buffer-name))))
         (default-directory (if project
                                (expand-file-name (project-root project))
                              default-directory))
         (source (current-buffer))
         (min-priority (number-to-string flymake-credo-min-priority)))
    (save-restriction
      (widen)

      (setq flymake-credo--proc
            (make-process
             :name "flymake-credo"
             :noquery t
             :connection-type 'pipe
             :buffer (get-buffer-create buffer-name)
             :command `(,@flymake-credo--command
                        "list"
                        ,(if flymake-credo-strict "--strict" "")
                        "--format"
                        "json"
                        "--min-priority"
                        ,min-priority
                        ,(if flymake-credo-config-file (concat "--config-file=" flymake-credo-config-file) "")
                        ,(if flymake-credo-config-name (concat "--config-name=" flymake-credo-config-name) "")
                        "--read-from-stdin")
             :stderr stderr-buffer-name
             :sentinel
             (lambda (proc _event)
               (when (eq 'exit (process-status proc))
                 (unwind-protect
                     (with-current-buffer source
                       (if (eq proc flymake-credo--proc)
                           (when-let* ((json-string (with-current-buffer (process-buffer proc)
                                                      (buffer-string)))
                                       (object (ignore-errors (json-parse-string
                                                               json-string
                                                               :null-object nil)))
                                       (issues (gethash "issues" object)))
                             (cl-loop
                              for issue across issues
                              for lineno = (or (gethash "line_no" issue) 0)
                              for column = (or (gethash "column" issue) (save-excursion
                                                                          (goto-line lineno)
                                                                          (back-to-indentation)
                                                                          (1+ (current-column))))
                              for column-end = (or (gethash "column_end" issue) (save-excursion
                                                                                  (goto-line lineno)
                                                                                  (end-of-line)
                                                                                  (1+ (current-column))))
                              for (beg . _end) = (flymake-diag-region source lineno column)
                              when lineno
                              collect (flymake-make-diagnostic source
                                                               beg
                                                               (+ beg (- column-end column))
                                                               :warning
                                                               (gethash "message" issue))
                              into diags
                              finally (funcall report-fn diags)))
                         (flymake-log :warning "Cancelling obsolete check %s"
                                      proc)))
                   (kill-buffer (process-buffer proc))
                   (kill-buffer stderr-buffer-name))))))

      (process-send-region flymake-credo--proc (point-min) (point-max))
      (process-send-eof flymake-credo--proc))))

;;;###autoload
(defun flymake-credo-load ()
  "Setup flymake to be used with credo linter."
  (add-hook 'flymake-diagnostic-functions #'flymake-credo nil t))

(add-hook 'elixir-mode-hook #'flymake-credo-load)

(provide 'flymake-credo)

;;; flymake-credo.el ends here
