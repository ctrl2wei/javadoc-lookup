;;; javadoc-lookup.el --- Javadoc Emacs integration

;; This is free and unencumbered software released into the public domain.

;;; Commentary:

;; This package provides a quick way to look up any Javadoc
;; documentation from Emacs, using your browser to display the
;; information. Since the mechanism is already there, java-import.el
;; provides the completing function `add-java-import' for quickly
;; adding an import to a source file.

;; To install, just drop this somewhere on your `load-path' and put
;; this in your .emacs,

;; (require 'javadoc-lookup)

;; Give `javadoc-lookup' your root Java documentation directories. It
;; will scan and index those directories, exposing them to
;; `javadoc-lookup'. Multiple directories can be provided at once, for
;; example,

;;   (javadoc-add "/usr/share/doc/openjdk-6-jdk/api" "~/src/project/doc")

;; Lookups can then be done with C-h j. If you haven't loaded the core
;; Java Javadoc, it will attempt to load a pre-made database for you,
;; which indexes the official website.

;; To view documentation, the browser is launched with `browse-url'.
;; This may require setting `browse-url-browser-function' in order to
;; select the proper browser. For example,

;;   (setq browse-url-browser-function 'browse-url-firefox)

;; This mode stores database and index information in
;; `javadoc-lookup-cache-dir'.

;;; Code:

(require 'cl)
(require 'ido)

(defgroup javadoc-lookup nil
  "Lookup Java library documentation from Emacs."
  :group 'java)

;; Customization variables

(defcustom javadoc-lookup-cache-dir (locate-user-emacs-file "javadoc-cache")
  "Filesystem location to store index and cache database.")

(defcustom javadoc-lookup-compress-index (and (executable-find "gzip") t)
  "When true, compress the cache using gzip.")

(defcustom javadoc-lookup-completing-read-function #'ido-completing-read
  "Function used when performing a minibuffer read.")

;; Internal variables

(defvar jdl/data-root (file-name-directory load-file-name)
  "The location of data for javadoc-loookup.")

(defvar jdl/index (make-hash-table :test 'equal)
  "Full index of for documentation lookups.")

(defvar jdl/cache-version "-v3"
  "Cache version, so it won't load old caches.")

(defvar jdl/loaded ()
  "List of already-loaded documentation directories.")

;; Indexing Functions

(defun jdl/dir-truename (dir)
  "Return the truename for DIR, which always has a trailing slash."
  (expand-file-name (concat dir "/")))

(defun jdl/clear ()
  "Clear all in-memory javadoc-lookup cache and indexes."
  (setq jdl/loaded nil)
  (setq jdl/index (make-hash-table :test 'equal)))

(defun jdl/loaded-p (dir)
  "Return t if DIR has already been loaded."
  (member dir jdl/loaded))

(defun jdl/cache-name (dir)
  "Get the cache file name for DIR."
  (concat (replace-regexp-in-string "[/:]" "+" dir) jdl/cache-version
          (if javadoc-lookup-compress-index ".gz" "")))

(defun jdl/load-cache (cache-file)
  "Load a cache from disk."
  (with-current-buffer (find-file-noselect cache-file)
    (goto-char (point-min))
    (jdl/add-hash (read (current-buffer)))
    (kill-buffer)))

(defun jdl/save-cache (cache-file hash)
  "Save a cache to the disk."
  (unless (file-exists-p javadoc-lookup-cache-dir)
    (make-directory javadoc-lookup-cache-dir t))
  (with-temp-file cache-file
    (prin1 hash (current-buffer))))

(defun jdl/add (dir)
  "Index DIR, using the cache if available."
  (let ((cache-file (expand-file-name (jdl/cache-name dir)
                                      javadoc-lookup-cache-dir)))
    (if (file-exists-p cache-file)
        (jdl/load-cache cache-file)
      (let ((hash (make-hash-table :test 'equal)))
        (jdl/index dir hash)
        (jdl/save-cache cache-file hash)
        (jdl/add-hash hash))))
  (add-to-list 'jdl/loaded dir))

(defun jdl/add-hash (hash)
  "Combine HASH into the main index hash."
  (maphash (lambda (key val) (puthash key val jdl/index)) hash))

(defun* jdl/index (dir hash &optional (root dir))
  "Index the documentation in DIR into HASH, based on ROOT."
  (let* ((list (directory-files dir t "^[^.]"))
         (files (remove-if 'file-directory-p list))
         (dirs (remove-if-not 'file-directory-p list)))
    (dolist (file files)
      (jdl/add-file file hash root))
    (dolist (dir dirs)
      (when (not (string-equal "class-use" (file-name-nondirectory dir)))
        (jdl/index dir hash root)))))

(defun jdl/add-file (fullfile hash root)
  "Add a file to the index if it looks like a class."
  (let* ((file (file-name-nondirectory fullfile))
         (ext (file-name-extension fullfile))
         (class (file-name-sans-extension file))
         (rel (substring fullfile (length root)))
         (fullclass (substitute ?. ?/ (file-name-sans-extension rel)))
         (case-fold-search nil))
    (when (and (string-equal ext "html")
               (string-match "^[A-Z].+" class))
      (puthash fullclass fullfile hash))))

(defun javadoc-add (&rest directories)
  "Index and load all documentation under DIRECTORIES."
  (loop for directory in directories
        for truename = (jdl/dir-truename directory)
        unless (jdl/loaded-p truename)
        do (jdl/add truename)))

(defun jdl/web (&rest urls)
  "Load pre-cached web indexes for URLS."
  (dolist (url (remove-if 'jdl/loaded-p urls))
    (let* ((rel-cache-file (concat "webcache/" (jdl/cache-name url)))
           (cache-file (expand-file-name rel-cache-file jdl/data-root)))
      (if (file-exists-p cache-file)
          (jdl/load-cache cache-file)
        (error "No cache for %s" url)))))

;; Lookup functions

(defun jdl/core-indexed-p ()
  "Return true if the JRE Javadoc has been indexed. The class
java.net.URL is used for this test, since it's simple and should
always be there."
  (gethash "java.net.URL" jdl/index))

(defun jdl/get-class-list ()
  (loop for class being the hash-keys of jdl/index
        collect class into classes
        finally (return (sort* classes #'< :key #'length))))

(defun jdl/completing-read ()
  "Query the user for a class name."
  (unless (jdl/core-indexed-p)
    (ignore-errors ; Provide *something* useful, if needed
      (jdl/web "http://download.oracle.com/javase/6/docs/api/")))
  (funcall javadoc-lookup-completing-read-function "Class: "
           (jdl/get-class-list)))

;;;###autoload
(defun javadoc-lookup (name)
  "Lookup based on class name."
  (interactive (list (jdl/completing-read)))
  (let ((file (gethash name jdl/index)))
    (when file (browse-url file))))

;;;###autoload
(global-set-key "\C-hj" 'javadoc-lookup)

(provide 'javadoc-lookup)

;;; javadoc-lookup.el ends here