;;; vite-test-mode.el --- Minor mode for running Node.js tests using vite -*- lexical-binding: t; -*-

;; Copyright (C) 2020 Raymond Huang

;; Author: Raymond Huang <rymndhng@gmail.com>
;; Maintainer: Raymond Huang <rymndhng@gmail.com>
;; URL: https://github.com/rymndhng/vite-test-mode.el
;; Version: 0
;; Package-Requires: ((emacs "25.1"))

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; This mode provides commands for running node tests using vite. The output is
;; shown in a separate buffer '*compilation*' in compilation mode. Backtraces
;; from failures and errors are marked and can be clicked to bring up the
;; relevant source file, where point is moved to the named line.
;;
;; The tests should be written with vite. File names are supposed to end in `.test.ts'
;;
;; Using the command `vite-test-run-at-point`, you can run test cases from the
;; current file.

;; Keybindings:
;;
;; C-c C-t n    - Runs the current buffer's file as an unit test or an rspec example.
;; C-c C-t p    - Runs all tests in the project
;; C-C C-t t    - Runs describe block at point
;; C-C C-t a    - Re-runs the last test command
;; C-c C-t d n  - With node debug enabled, runs the current buffer's file as an unit test or an rspec example.
;; C-C C-t d a  - With node debug enabled, re-runs the last test command
;; C-C C-t d t  - With node debug enabled, runs describe block at point


;;; Code:

;; Adds support for when-let
(eval-when-compile (require 'subr-x))

;; prevents warnings like
;; vite-test-mode.el:190:15:Warning: reference to free variable
;; ‘compilation-error-regexp-alist’
(require 'compile)

;; for seq-concatenate
(require 'seq)

(defgroup vite-test nil
  "Minor mode providing commands for running vite tests in Node.js."
  :group 'js)

(defcustom vite-test-options
  '("--color")
  "Pass extra command line options to vite when running tests."
  :initialize 'custom-initialize-default
  :type '(list string)
  :group 'vite-test-mode)

(defcustom vite-test-npx-options
  '()
  "Pass extra command line arguments to npx when running tests."
  :initialize 'custom-initialize-default
  :type '(list string)
  :group 'vite-test-mode)

(defcustom vite-test-command-string
  "npx %s vite %s %s"
  "The command by which vite is run.

Placeholders are:

1. npx options (`vite-test-npx-options')
2. Vite test options (`vite-test-options')
3. The file name"
  :initialize 'custom-initialize-default
  :type 'string
  :group 'vite-test-mode)

(defvar vite-test-last-test-command
  nil
  "The last test command ran with.")

(defvar vite-test-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-t p")   'vite-test-run-all-tests)
    (define-key map (kbd "C-c C-t C-p") 'vite-test-run-all-tests)
    (define-key map (kbd "C-c C-t n")   'vite-test-run)
    (define-key map (kbd "C-c C-t C-n") 'vite-test-run)
    (define-key map (kbd "C-c C-t a")   'vite-test-rerun-test)
    (define-key map (kbd "C-c C-t C-a") 'vite-test-rerun-test)
    (define-key map (kbd "C-c C-t t")   'vite-test-run-at-point)
    (define-key map (kbd "C-c C-t C-t") 'vite-test-run-at-point)
    (define-key map (kbd "C-c C-t d n") 'vite-test-debug)
    (define-key map (kbd "C-c C-t d a") 'vite-test-debug-rerun-test)
    (define-key map (kbd "C-c C-t d t") 'vite-test-debug-run-at-point)

    ;; (define-key map (kbd "C-c C-s")     'vite-test-toggle-implementation-and-test)
    map)
  "The keymap used in command `vite-test-mode' buffers.")

;;;###autoload
(define-minor-mode vite-test-mode
  "Toggle vite minor mode.
With no argument, this command toggles the mode. Non-null prefix
argument turns on the mode. Null prefix argument turns off the
mode"
  :init-value nil
  :lighter " Vite"
  :keymap 'vite-test-mode-map
  :group 'vite-test-mode)

(defmacro vite-test-from-project-directory (filename form)
  "Set to npm project root inferred from FILENAME.

Runs the provided FORM with `default-directory` bound."
  (declare (indent 1))
  `(let ((default-directory (or (vite-test-project-root ,filename)
                                default-directory)))
     ,form))

(defmacro vite-test-with-debug-flags (form)
  "Execute FORM with debugger flags set."
  (declare (indent 0))
  `(let ((vite-test-options (seq-concatenate 'list vite-test-options (list "--runInBand") ))
         (vite-test-npx-options (seq-concatenate 'list vite-test-npx-options (list "--node-arg" "inspect"))))
     ,form))

(defun vite-test-project-root (filename)
  "Find project folder containing a package.json containing FILENAME."
  (if (vite-test-npm-project-root-p filename)
      filename
    (and filename
         (not (string= "/" filename))
         (vite-test-project-root
          (file-name-directory
           (directory-file-name (file-name-directory filename)))))))

(defun vite-test-npm-project-root-p (directory)
  "Check if DIRECTORY contain a package.json file."
  (file-exists-p (concat (file-name-as-directory directory) "/package.json")))

(defun vite-test-find-file ()
  "Find the testfile to run. Assumed to be the current file."
  (buffer-file-name))

(defvar vite-test-not-found-message "No test among visible bufers")

;;;###autoload
(defun vite-test-run ()
  "Run the current buffer's file as a test."
  (interactive)
  (let ((filename (vite-test-find-file)))
    (if filename
        (vite-test-from-project-directory filename
                                          (vite-test-run-command (vite-test-command filename)))
      (message vite-test-not-found-message))))

(defun vite-test-run-all-tests ()
  "Run all test in the project."
  (interactive)
  (vite-test-from-project-directory (buffer-file-name)
                                    (vite-test-run-command (vite-test-command ""))))

(defun vite-test-rerun-test ()
  "Run the previously run test in the project."
  (interactive)
  (vite-test-from-project-directory (buffer-file-name)
                                    (vite-test-run-command vite-test-last-test-command)))

(defun vite-test-run-at-point ()
  "Run the enclosing it/test/describe block surrounding the current point."
  (interactive)
  (let ((filename (vite-test-find-file))
        (test (vite-test-unit-at-point)))
    (if (and filename test)
        (vite-test-from-project-directory filename
                                          (let ((vite-test-options (seq-concatenate 'list vite-test-options (list "-t" test))))
                                            (vite-test-run-command (vite-test-command filename))))
      (message vite-test-not-found-message))))

(defun vite-test-debug ()
  "Run the test with an inline debugger attached."
  (interactive)
  (vite-test-with-debug-flags
   (vite-test-run)))

(defun vite-test-debug-rerun-test ()
  "Run the test with an inline debugger attached."
  (interactive)
  (vite-test-with-debug-flags
   (vite-test-rerun-test)))

(defun vite-test-debug-run-at-point ()
  "Run the test with an inline debugger attached."
  (interactive)
  (vite-test-with-debug-flags
   (vite-test-run-at-point)))

(defvar vite-test-declaration-regex "^[ \\t]*\\(it\\|test\\|describe\\)\\(\\.\\(.*\\)\\)?(\\(.*\\),"
  "Regex for finding a test declaration in vite.

Match Group 1 contains the function name: it, test, describe
Match Group 4 contains the test name" )

(defun vite-test-unit-at-point ()
  "Find the enclosing name of the block.

Looks for it, test or describe from where the cursor is"
  (save-excursion
    ;; Moving the cursor to the end will allow matching the current line
    (move-end-of-line nil)
    (when (re-search-backward vite-test-declaration-regex nil t)
      (when-let ((name (match-string 4)))
        (substring name 1 -1)))))

(defun vite-test-update-last-test (command)
  "Update the last test COMMAND."
  (setq vite-test-last-test-command command))

(defun vite-test-run-command (command)
  "Run compilation COMMAND in NPM project root."
  (vite-test-update-last-test command)
  (let ((comint-scroll-to-bottom-on-input t)
        (comint-scroll-to-bottom-on-output t)
        (comint-process-echoes t)
        (compilation-buffer-name-function 'vite-test-compilation-buffer-name))
    ;; TODO: figure out how to prevent <RET> from re-sending the old input
    ;; See https://stackoverflow.com/questions/51275228/avoid-accidental-execution-in-comint-mode
    (compile command 'vite-test-compilation-mode)))

;;;###autoload
(defun vite-test-command (filename)
  "Format test arguments for FILENAME."
  (format vite-test-command-string
          (mapconcat #'shell-quote-argument vite-test-npx-options " ")
          (mapconcat #'shell-quote-argument vite-test-options " ")
          (if (string-empty-p filename)
              filename
            (file-relative-name filename (vite-test-project-root filename)))))

;;; compilation-mode support

;; Source: https://emacs.stackexchange.com/questions/27213/how-can-i-add-a-compilation-error-regex-for-node-js
;; Handle errors that match this:
;; at addSpecsToSuite (node_modules/vite-jasmine2/build/jasmine/Env.js:522:17)
(defvar vite-test-compilation-error-regexp-alist-alist
  '((vite "at [^ ]+ (\\(.+?\\):\\([[:digit:]]+\\):\\([[:digit:]]+\\)" 1 2 3)))

(defvar vite-test-compilation-error-regexp-alist
  (mapcar 'car vite-test-compilation-error-regexp-alist-alist))

(define-compilation-mode vite-test-compilation-mode "Vite Compilation"
  "Compilation mode for Vite output."
  (add-hook 'compilation-filter-hook 'vite-test-colorize-compilation-buffer nil t))

(defun vite-test-colorize-compilation-buffer ()
  "Colorize the compilation buffer."
  (ansi-color-apply-on-region compilation-filter-start (point)))

(defconst vite-test-compilation-buffer-name-base "*vite-test-compilation*")

(defun vite-test-compilation-buffer-name (&rest _)
  "Return the name of a compilation buffer."
  vite-test-compilation-buffer-name-base)

(defun vite-test-enable ()
  "Enable the vite test mode."
  (vite-test-mode 1))

(provide 'vite-test-mode)
;; Local Variables:
;; sentence-end-double-space: nil
;; checkdoc-spellcheck-documentation-flag: nil
;; End:
;;; vite-test-mode.el ends here
