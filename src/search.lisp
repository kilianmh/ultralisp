(defpackage #:ultralisp/search
  (:use #:cl)
  (:import-from #:dexador)
  (:import-from #:jonathan)
  (:import-from #:closer-mop)
  (:import-from #:rutils
                #:fmt)
  (:import-from #:alexandria
                #:make-keyword)
  (:import-from #:ultralisp/downloader/base
                #:downloaded-project-path
                #:download)
  (:import-from #:ultralisp/models/project
                #:get-recently-updated-projects
                #:get-all-projects
                #:get-github-project)
  (:import-from #:ultralisp/packages-extractor-api
                #:get-packages)
  (:import-from #:ultralisp/rpc/core
                #:submit-task)
  (:import-from #:log4cl-json
                #:with-log-unhandled)
  (:export
   #:search-objects
   #:bad-query))
(in-package ultralisp/search)


(defparameter *elastic-host* "elastic")

(defvar *current-system-name* nil)
(defvar *current-project-name* nil)


(defun index (collection id data)
  (let ((content (jonathan:to-json data))
        (url (fmt "http://~A:9200/~A/_doc/~A"
                  *elastic-host*
                  collection
                  (quri:url-encode id))))
    (jonathan:parse
     (dex:put url
              :content content
              :headers '(("Content-Type" . "application/json"))))))


(defun delete-index ()
  (let ((url (fmt "http://~A:9200/symbols"
                  *elastic-host*)))
    (jonathan:parse
     (dex:delete url :headers '(("Content-Type" . "application/json"))))))


(define-condition bad-query (error)
  ())


(defun search-objects (term)
  ;; TODO: научиться обрабатывать 400 ответы от Elastic
  ;; например на запрос: TYPE:macro AND storage NAME:FLEXI-STREAMS:WITH-OUTPUT-TO-SEQUENCE
  (handler-case
      (loop with url = (fmt "http://~A:9200/symbols/_search"
                            *elastic-host*)
            with query = (list
                          :|query| (list
                                    :|query_string|
                                    (list :|fields|
                                          (list "documentation" "name")
                                          :|query| term)))
            with content = (jonathan:to-json query)
            with response = (jonathan:parse (dex:post url
                                                      :content content
                                                      :headers '(("Content-Type" . "application/json"))))
            for hit in (getf (getf response
                                   :|hits|)
                             :|hits|)
            for name = (getf hit :|_id|)
            for source = (getf hit :|_source|)
            for doc = (getf source :|documentation|)
            for type = (getf source :|type|)
            for system = (getf source :|system|)
            for project = (getf source :|project|)
            collect (list (make-keyword type)
                          name
                          doc
                          :arguments (getf source :|arguments|)
                          :system system
                          :project project))
    (dexador.error:http-request-not-found ()
      nil)
    (dexador.error:http-request-bad-request ()
      (error 'bad-query))))


(defun symbol-function-type (symbol)
  (cond
    ((macro-function symbol)
     'macro)
    ((fboundp symbol)
     (type-of (fdefinition symbol)))))


(defun encode-symbol (symbol &optional (ftm-string "~a"))
  "Encode the symbol as a string, including the package.  If the value
is a string then just return the string."
  (let ((sym-string
          (etypecase symbol
            (string symbol)
            (symbol
             (let ((symbol-package (symbol-package symbol)))
               (concatenate
                'string
                (if symbol-package
                    (package-name symbol-package)
                    "")
                (cond
                  ((null symbol-package)
                   "#:")
                  ((multiple-value-bind
                         (sym status)
                       (find-symbol (symbol-name symbol)
                                    (package-name symbol-package))
                     (declare (ignore sym))
                     (member status '(:inherited :external)))
                   ":")
                  (t "::"))
                (symbol-name symbol))))
            ;; TODO: придумать что-то с type-specifier которые не являются
            ;;       символами а являются объектами
            (t symbol))))
    (format nil ftm-string sym-string)))


(defun is-external (symbol package)
  (multiple-value-bind
        (sym status)
      (find-symbol (symbol-name symbol) package)
    (declare (ignore sym))
    (eql status :external)))


(defun simplify-arglist (arglist)
  "return the first element of each list item this is to remove the
default values from the arglist."
  (mapcar (lambda (e)
            (cond
              ((listp e)
               (car e))
              (t e)))
          arglist))


(defun encode-xref (symbol)
  (encode-symbol symbol ":cl:symbol:`~~~a`"))


(defun encode-literal (symbol)
  (if (equal (symbol-package symbol) (find-package 'keyword))
      (format nil "``~s``" symbol)
      (format nil "``~a``" symbol)))


(defun prepare-text (text)
  "Removes spaces from left and right of each line, then joins
   lines not separated by an empty line into single paragraphs."
  (with-output-to-string (output)
    (loop with add-space = nil
          with some-lines-written = nil
          for line in (rutil:split #\Newline text)
          for stripped = (string-trim '(#\Space)
                                      line)
          when add-space
            do (write-char #\Space output)
          when (> (length stripped) 0)
            do (write-string stripped output)
               (setf add-space t
                     some-lines-written t)
          else
            when some-lines-written
              do (write-char #\Newline output)
                 (write-char #\Newline output)
                 (setf add-space nil
                       some-lines-written nil))))

(defun arglist-as-string (symbol)
  (let ((*package* (symbol-package symbol))
        (*print-case* :downcase))
    (format nil "~S"
            (arglist symbol))))

(defun get-function-documentation* (symbol type doc)
  (append
   (when *current-system-name*
     (list :|system| *current-system-name*))
   
   (when *current-project-name*
     (list :|project| *current-project-name*))
   
   (list :|type| type
         :|name| (string-downcase
                  (symbol-name symbol))
         :|package| (string-downcase
                     (package-name (symbol-package symbol)))
         :|documentation| (prepare-text doc)
         :|arguments| (arglist-as-string symbol))))


(defun encode-class (symbol)
  "Encode a class as a string including the package."
  (encode-symbol (class-name symbol)))


(defun encode-specializer (atom)
  "encode a single specializer lambda list"
  (cond ((eq (type-of atom) 'closer-mop:eql-specializer)
         (concatenate 'string
                      "(EQ " (encode-symbol
                              (closer-mop:eql-specializer-object atom)) ")"))
        ((closer-mop:classp atom)
         (encode-class atom))
        (t (encode-symbol atom))))


(defun get-methods (generic-function)
  (loop with methods = (closer-mop:generic-function-methods generic-function)
        for method in methods
        for specializers = (closer-mop:method-specializers method)
        for lambda-list = (closer-mop:method-lambda-list method)
        collect (list
                 (fmt "~A"
                      (mapcar #'encode-specializer specializers))
                 (or (documentation method t) ""))))


(defgeneric get-function-documentation (symbol type)
  (:documentation
   "Encode documentation for a function or macro as a JSON object member."))

(defmethod get-function-documentation (symbol (type (eql 'function)))
  (get-function-documentation*
   symbol type (or (documentation symbol type) "")))

;; CLISP-ism (might be other CL's as well): compiled functions are still
;; functions:
(defmethod get-function-documentation (symbol (type (eql 'compiled-function)))
  (get-function-documentation*
   symbol 'function (or (documentation symbol 'function) "")))

(defmethod get-function-documentation (symbol (type (eql 'macro)))
  (get-function-documentation*
   symbol type (or (documentation symbol 'function) "")))

(defmethod get-function-documentation (symbol (type (eql 'generic-function)))
  (append
   (get-function-documentation*
    symbol type (or (documentation symbol 'function) ""))
   (list :methods
         (get-methods (symbol-function symbol)))))

(defmethod get-function-documentation (symbol (type (eql 'cl:standard-generic-function)))
  (get-function-documentation symbol 'generic-function))

#+continuations
(defmethod get-function-documentation (symbol (type (eql 'cl-cont::funcallable/cc)))
  (get-function-documentation symbol 'function))


(defun class-p (symbol)
  "Return T if the symbol is a class."
  #+sbcl (eql (sb-int:info :type :kind symbol) :instance)
  #-sbcl (find-class symbol nil))


(defun variable-p (symbol)
  "Return T if the symbol is a bound variable."
  (and #+sbcl (sb-int:info :variable :kind symbol)
       (boundp symbol)))


(defun get-variable-documentation* (symbol type)
  (append
   (when *current-system-name*
     (list :|system| *current-system-name*))
   
   (when *current-project-name*
     (list :|project| *current-project-name*))
   
   (list
    :|type| type
    :|documentation| (prepare-text (or (documentation symbol type) "")))))


(defun arglist (symbol)
  #+sbcl  (sb-introspect:function-lambda-list symbol)
  #+clisp (sys::arglist symbol)
  #+ccl (ccl:arglist symbol)
  #+ecl   (ext:function-lambda-list symbol)
  #-(or sbcl clisp ccl ecl) (error "arglist not available for this Lisp."))


(defmethod get-value-documentation (symbol (type (eql 'variable)))
  (get-variable-documentation* symbol type))

(defmethod get-value-documentation (symbol (type (eql 'setf)))
  (get-function-documentation* symbol type (or (documentation symbol 'setf) "")))

(defun get-class-slots (sym)
  (loop for slot in (closer-mop:class-direct-slots (find-class sym))
        collect (list
                 :name (closer-mop:slot-definition-name slot)
                 :initarg (write-to-string (closer-mop:slot-definition-initargs slot))
                 :readers (write-to-string (closer-mop:slot-definition-readers slot))
                 :writers (car (closer-mop:slot-definition-writers slot))
                 :type (class-name (class-of slot))
                 :documentation (or (documentation slot t) ""))))

(defmethod get-value-documentation (symbol (type (eql 'type)))
  (list*
   :|slots| (get-class-slots symbol)
   (get-variable-documentation* symbol type)))


(defun index-symbols (package)
  (let ((current-package (etypecase package
                           (string (find-package (string-upcase package)))
                           (keyword (find-package package))
                           (package package))))
    (cond
      (current-package
       (do-external-symbols (symbol current-package)
         (let ((external (is-external symbol package)))
           (when external
             (let* ((full-symbol-name (encode-symbol symbol))
                    (object-id (if *current-project-name*
                                   (fmt "~A:~A" *current-project-name* full-symbol-name)
                                   full-symbol-name)))
               (when (symbol-function-type symbol)
                 (index "symbols"
                        object-id
                        (get-function-documentation symbol
                                                    (symbol-function-type symbol))))
             
               (when (class-p symbol)
                 (index "symbols"
                        object-id
                        (get-value-documentation symbol 'type)))
             
               (when (variable-p symbol)
                 (index "symbols"
                        object-id
                        (get-value-documentation symbol 'variable))))))))
      (t (log:error "Unable to find package" package)))))


(defun index-all-packages ()
  "Временная функция для тестирования индесатора"
  (mapc #'index-symbols (list-all-packages)))


(defun index-project (project)
  "Эту функцию надо вызывать внутри воркера."
  (let* ((tmp-dir "/tmp/indexer")
         (downloaded (download project tmp-dir :latest t))
         (path (downloaded-project-path downloaded)))
    
    (unwind-protect
         (loop with systems = (ultralisp/models/project:get-systems-info project)
               with *current-project-name* = (ultralisp/models/project:get-name project)
               for system in systems
               for data = (get-packages (quickdist:get-name system))
               do (loop for item in data
                        for *current-system-name* = (getf item :system)
                        for packages = (getf item :packages)
                        do (mapc #'index-symbols
                                 packages)))
      ;; Here we need to make a clean up to not clutter the file system
      (log:info "Deleting checked out" path)
      (uiop:delete-directory-tree path
                                  :validate t))))


(defun index-projects (&key names since)
  (when (and names since)
    (error "Only \"since\" or \"names\" should be specified"))
  
  (let ((projects (cond
                    (names
                     (loop for name in names
                           for splitted = (cl-strings:split name #\/)
                           collect (get-github-project (first splitted)
                                                       (second splitted))))
                    (since (get-recently-updated-projects
                            :since since))
                    ;; Reindexing all projects
                    (t (get-all-projects :only-enabled t)))))
    (loop for project in projects
          do (log:info "Indexing project" project)
             (ignore-errors
              (log4cl-json:with-fields
                  (:project-name (ultralisp/models/project:get-name project))
                (with-log-unhandled ()
                  (submit-task
                   'index-project project)))))))