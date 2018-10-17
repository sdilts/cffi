;;;; -*- Mode: lisp; indent-tabs-mode: nil -*-
;;;
;;; grovel.lisp --- The CFFI Groveller.
;;;
;;; Copyright (C) 2005-2006, Dan Knap <dankna@accela.net>
;;; Copyright (C) 2005-2006, Emily Backes <lucca@accela.net>
;;; Copyright (C) 2007, Stelian Ionescu <sionescu@cddr.org>
;;; Copyright (C) 2007, Luis Oliveira <loliveira@common-lisp.net>
;;;
;;; Permission is hereby granted, free of charge, to any person
;;; obtaining a copy of this software and associated documentation
;;; files (the "Software"), to deal in the Software without
;;; restriction, including without limitation the rights to use, copy,
;;; modify, merge, publish, distribute, sublicense, and/or sell copies
;;; of the Software, and to permit persons to whom the Software is
;;; furnished to do so, subject to the following conditions:
;;;
;;; The above copyright notice and this permission notice shall be
;;; included in all copies or substantial portions of the Software.
;;;
;;; THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
;;; EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
;;; MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
;;; NONINFRINGEMENT.  IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
;;; HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
;;; WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
;;; OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
;;; DEALINGS IN THE SOFTWARE.
;;;

(in-package #:cffi-grovel)

;;;# Error Conditions

(define-condition grovel-error (simple-error) ())

(defun grovel-error (format-control &rest format-arguments)
  (error 'grovel-error
         :format-control format-control
         :format-arguments format-arguments))

;;; This warning is signalled when cffi-grovel can't find some macro.
;;; Signalled by CONSTANT or CONSTANTENUM.
(define-condition missing-definition (warning)
  ((%name :initarg :name :reader name-of))
  (:report (lambda (condition stream)
             (format stream "No definition for ~A"
                     (name-of condition)))))

;;;# Grovelling

;;; The header of the intermediate C file.
(defparameter *header*
  "/*
 * This file has been automatically generated by cffi-grovel.
 * Do not edit it by hand.
 */

")

;;; C code generated by cffi-grovel is inserted between the contents
;;; of *PROLOGUE* and *POSTSCRIPT*, inside the main function's body.

(defparameter *prologue*
  "
#include <grovel/common.h>

int main(int argc, char**argv) {
  int autotype_tmp;
  FILE *output = argc > 1 ? fopen(argv[1], \"w\") : stdout;
  fprintf(output, \";;;; This file has been automatically generated by \"
                  \"cffi-grovel.\\n;;;; Do not edit it by hand.\\n\\n\");
")

(defparameter *postscript*
  "
  if  (output != stdout)
    fclose(output);
  return 0;
}
")

(defun unescape-for-c (text)
  (with-output-to-string (result)
    (loop for i below (length text)
          for char = (char text i) do
          (cond ((eql char #\") (princ "\\\"" result))
                ((eql char #\newline) (princ "\\n" result))
                (t (princ char result))))))

(defun c-format (out fmt &rest args)
  (let ((text (unescape-for-c (format nil "~?" fmt args))))
    (format out "~&  fputs(\"~A\", output);~%" text)))

(defun c-printf (out fmt &rest args)
  (flet ((item (item)
           (format out "~A" (unescape-for-c (format nil item)))))
    (format out "~&  fprintf(output, \"")
    (item fmt)
    (format out "\"")
    (loop for arg in args do
          (format out ", ")
          (item arg))
    (format out ");~%")))

(defun c-print-integer-constant (out arg &optional foreign-type)
  (let ((foreign-type (or foreign-type :int)))
    (c-format out "#.(cffi-grovel::convert-intmax-constant ")
    (format out "~&  fprintf(output, \"%\"PRIiMAX, (intmax_t)~A);~%"
            arg)
    (c-format out " ")
    (c-write out `(quote ,foreign-type))
    (c-format out ")")))

;;; TODO: handle packages in a better way. One way is to process each
;;; grovel form as it is read (like we already do for wrapper
;;; forms). This way in can expect *PACKAGE* to have sane values.
;;; This would require that "header forms" come before any other
;;; forms.
(defun c-print-symbol (out symbol &optional no-package)
  (c-format out
            (let ((package (symbol-package symbol)))
              (cond
                ((eq (find-package '#:keyword) package) ":~(~A~)")
                (no-package "~(~A~)")
                ((eq (find-package '#:cl) package) "cl:~(~A~)")
                (t "~(~A~)")))
            symbol))

(defun c-write (out form &optional no-package)
  (cond
    ((and (listp form)
          (eq 'quote (car form)))
     (c-format out "'")
     (c-write out (cadr form) no-package))
    ((listp form)
     (c-format out "(")
     (loop for subform in form
           for first-p = t then nil
           unless first-p do (c-format out " ")
        do (c-write out subform no-package))
     (c-format out ")"))
    ((symbolp form)
     (c-print-symbol out form no-package))))

;;; Always NIL for now, add {ENABLE,DISABLE}-AUTO-EXPORT grovel forms
;;; later, if necessary.
(defvar *auto-export* nil)

(defun c-export (out symbol)
  (when (and *auto-export* (not (keywordp symbol)))
    (c-format out "(cl:export '")
    (c-print-symbol out symbol t)
    (c-format out ")~%")))

(defun c-section-header (out section-type section-symbol)
  (format out "~%  /* ~A section for ~S */~%"
          section-type
          section-symbol))

(defun remove-suffix (string suffix)
  (let ((suffix-start (- (length string) (length suffix))))
    (if (and (> suffix-start 0)
             (string= string suffix :start1 suffix-start))
        (subseq string 0 suffix-start)
        string)))

(defgeneric %process-grovel-form (name out arguments)
  (:method (name out arguments)
    (declare (ignore out arguments))
    (grovel-error "Unknown Grovel syntax: ~S" name)))

(defun process-grovel-form (out form)
  (%process-grovel-form (form-kind form) out (cdr form)))

(defun form-kind (form)
  ;; Using INTERN here instead of FIND-SYMBOL will result in less
  ;; cryptic error messages when an undefined grovel/wrapper form is
  ;; found.
  (intern (symbol-name (car form)) '#:cffi-grovel))

(defvar *header-forms* '(c include define flag typedef))

(defun header-form-p (form)
  (member (form-kind form) *header-forms*))

(defun generate-c-file (input-file output-defaults)
  (nest
   (with-standard-io-syntax)
   (let ((c-file (make-c-file-name output-defaults "__grovel"))
         (*print-readably* nil)
         (*print-escape* t)))
   (with-open-file (out c-file :direction :output :if-exists :supersede))
   (with-open-file (in input-file :direction :input))
   (flet ((read-forms (s)
            (do ((forms ())
                 (form (read s nil nil) (read s nil nil)))
                ((null form) (nreverse forms))
              (labels
                  ((process-form (f)
                     (case (form-kind f)
                       (flag (warn "Groveler clause FLAG is deprecated, use CC-FLAGS instead.")))
                     (case (form-kind f)
                       (in-package
                        (setf *package* (find-package (second f)))
                        (push f forms))
                       (progn
                         ;; flatten progn forms
                         (mapc #'process-form (rest f)))
                       (t (push f forms)))))
                (process-form form))))))
   (let* ((forms (read-forms in))
          (header-forms (remove-if-not #'header-form-p forms))
          (body-forms (remove-if #'header-form-p forms)))
     (write-string *header* out)
     (dolist (form header-forms)
       (process-grovel-form out form))
     (write-string *prologue* out)
     (dolist (form body-forms)
       (process-grovel-form out form))
     (write-string *postscript* out)
     c-file)))

(defun tmp-lisp-file-name (defaults)
  (make-pathname :name (strcat (pathname-name defaults) ".grovel-tmp")
                 :type "lisp" :defaults defaults))



;;; *PACKAGE* is rebound so that the IN-PACKAGE form can set it during
;;; *the extent of a given grovel file.
(defun process-grovel-file (input-file &optional (output-defaults input-file))
  (with-standard-io-syntax
    (let* ((c-file (generate-c-file input-file output-defaults))
           (o-file (make-o-file-name c-file))
           (exe-file (make-exe-file-name c-file))
           (lisp-file (tmp-lisp-file-name c-file))
           (inputs (list (cc-include-grovel-argument) c-file)))
      (handler-case
          (progn
            ;; at least MKCL wants to separate compile and link
            (cc-compile o-file inputs)
            (link-executable exe-file (list o-file)))
        (error (e)
          (grovel-error "~a" e)))
      (invoke exe-file lisp-file)
      lisp-file)))

;;; OUT is lexically bound to the output stream within BODY.
(defmacro define-grovel-syntax (name lambda-list &body body)
  (with-unique-names (name-var args)
    `(defmethod %process-grovel-form ((,name-var (eql ',name)) out ,args)
       (declare (ignorable out))
       (destructuring-bind ,lambda-list ,args
         ,@body))))

(define-grovel-syntax c (body)
  (format out "~%~A~%" body))

(define-grovel-syntax include (&rest includes)
  (format out "~{#include <~A>~%~}" includes))

(define-grovel-syntax define (name &optional value)
  (format out "#define ~A~@[ ~A~]~%" name value))

(define-grovel-syntax typedef (base-type new-type)
  (format out "typedef ~A ~A;~%" base-type new-type))

;;; Is this really needed?
(define-grovel-syntax ffi-typedef (new-type base-type)
  (c-format out "(cffi:defctype ~S ~S)~%" new-type base-type))

(define-grovel-syntax flag (&rest flags)
  (unionf *cc-flags* (parse-command-flags-list flags) :test #'string=))

(define-grovel-syntax cc-flags (&rest flags)
  (unionf *cc-flags* (union *cc-flags* (parse-command-flags-list flags) :test #'string=)))

(define-grovel-syntax pkg-config-cflags (pkg &key optional)
  (let ((output-stream (make-string-output-stream))
        (program+args (list "pkg-config" pkg "--cflags")))
    (format *debug-io* "~&;~{ ~a~}~%" program+args)
    (handler-case
        (progn
          (run-program program+args
                       :output (make-broadcast-stream output-stream *debug-io*)
                       :error-output output-stream)
          (unionf *cc-flags*
                   (parse-command-flags (get-output-stream-string output-stream)) :test #'string=))
      (error (e)
        (let ((message (format nil "~a~&~%~a~&"
                               e (get-output-stream-string output-stream))))
          (cond (optional
                 (format *debug-io* "~&; ERROR: ~a" message)
                 (format *debug-io* "~&~%; Attempting to continue anyway.~%"))
                (t
                 (grovel-error "~a" message))))))))

;;; This form also has some "read time" effects. See GENERATE-C-FILE.
(define-grovel-syntax in-package (name)
  (c-format out "(cl:in-package #:~A)~%~%" name))

(define-grovel-syntax ctype (lisp-name size-designator)
  (c-section-header out "ctype" lisp-name)
  (c-export out lisp-name)
  (c-format out "(cffi:defctype ")
  (c-print-symbol out lisp-name t)
  (c-format out " ")
  (format out "~&  type_name(output, TYPE_SIGNED_P(~A), ~:[sizeof(~A)~;~D~]);~%"
          size-designator
          (etypecase size-designator
            (string nil)
            (integer t))
          size-designator)
  (c-format out ")~%")
  (unless (keywordp lisp-name)
    (c-export out lisp-name))
  (let ((size-of-constant-name (symbolicate '#:size-of- lisp-name)))
    (c-export out size-of-constant-name)
    (c-format out "(cl:defconstant "
              size-of-constant-name lisp-name)
    (c-print-symbol out size-of-constant-name)
    (c-format out " (cffi:foreign-type-size '")
    (c-print-symbol out lisp-name)
    (c-format out "))~%")))

;;; Syntax differs from anything else in CFFI.  Fix?
(define-grovel-syntax constant ((lisp-name &rest c-names)
                                &key (type 'integer) documentation optional)
  (when (keywordp lisp-name)
    (setf lisp-name (format-symbol "~A" lisp-name)))
  (c-section-header out "constant" lisp-name)
  (dolist (c-name c-names)
    (format out "~&#ifdef ~A~%" c-name)
    (c-export out lisp-name)
    (c-format out "(cl:defconstant ")
    (c-print-symbol out lisp-name t)
    (c-format out " ")
    (ecase type
      (integer
       (format out "~&  if(_64_BIT_VALUE_FITS_SIGNED_P(~A))~%" c-name)
       (format out "    fprintf(output, \"%lli\", (long long signed) ~A);" c-name)
       (format out "~&  else~%")
       (format out "    fprintf(output, \"%llu\", (long long unsigned) ~A);" c-name))
      (double-float
       (format out "~&  fprintf(output, \"%s\", print_double_for_lisp((double)~A));~%" c-name)))
    (when documentation
      (c-format out " ~S" documentation))
    (c-format out ")~%")
    (format out "~&#else~%"))
  (unless optional
    (c-format out "(cl:warn 'cffi-grovel:missing-definition :name '~A)~%"
              lisp-name))
  (dotimes (i (length c-names))
    (format out "~&#endif~%")))

(define-grovel-syntax cunion (union-lisp-name union-c-name &rest slots)
  (let ((documentation (when (stringp (car slots)) (pop slots))))
    (c-section-header out "cunion" union-lisp-name)
    (c-export out union-lisp-name)
    (dolist (slot slots)
      (let ((slot-lisp-name (car slot)))
        (c-export out slot-lisp-name)))
    (c-format out "(cffi:defcunion (")
    (c-print-symbol out union-lisp-name t)
    (c-printf out " :size %llu)" (format nil "(long long unsigned) sizeof(~A)" union-c-name))
    (when documentation
      (c-format out "~%  ~S" documentation))
    (dolist (slot slots)
      (destructuring-bind (slot-lisp-name slot-c-name &key type count)
          slot
        (declare (ignore slot-c-name))
        (c-format out "~%  (")
        (c-print-symbol out slot-lisp-name t)
        (c-format out " ")
        (c-write out type)
        (etypecase count
          (integer
           (c-format out " :count ~D" count))
          ((eql :auto)
           ;; nb, works like :count :auto does in cstruct below
           (c-printf out " :count %llu"
                     (format nil "(long long unsigned) sizeof(~A)" union-c-name)))
          (null t))
        (c-format out ")")))
    (c-format out ")~%")))

(defun make-from-pointer-function-name (type-name)
  (symbolicate '#:make- type-name '#:-from-pointer))

;;; DEFINE-C-STRUCT-WRAPPER (in ../src/types.lisp) seems like a much
;;; cleaner way to do this.  Unless I can find any advantage in doing
;;; it this way I'll delete this soon.  --luis
(define-grovel-syntax cstruct-and-class-item (&rest arguments)
  (process-grovel-form out (cons 'cstruct arguments))
  (destructuring-bind (struct-lisp-name struct-c-name &rest slots)
      arguments
    (declare (ignore struct-c-name))
    (let* ((slot-names (mapcar #'car slots))
           (reader-names (mapcar
                          (lambda (slot-name)
                            (intern
                             (strcat (symbol-name struct-lisp-name) "-"
                                     (symbol-name slot-name))))
                          slot-names))
           (initarg-names (mapcar
                           (lambda (slot-name)
                             (intern (symbol-name slot-name) "KEYWORD"))
                           slot-names))
           (slot-decoders (mapcar (lambda (slot)
                                    (destructuring-bind
                                          (lisp-name c-name
                                                     &key type count
                                                     &allow-other-keys)
                                        slot
                                      (declare (ignore lisp-name c-name))
                                      (cond ((and (eq type :char) count)
                                             'cffi:foreign-string-to-lisp)
                                            (t nil))))
                                  slots))
           (defclass-form
            `(defclass ,struct-lisp-name ()
               ,(mapcar (lambda (slot-name initarg-name reader-name)
                          `(,slot-name :initarg ,initarg-name
                                       :reader ,reader-name))
                        slot-names
                        initarg-names
                        reader-names)))
           (make-function-name
            (make-from-pointer-function-name struct-lisp-name))
           (make-defun-form
            ;; this function is then used as a constructor for this class.
            `(defun ,make-function-name (pointer)
               (cffi:with-foreign-slots
                   (,slot-names pointer ,struct-lisp-name)
                 (make-instance ',struct-lisp-name
                                ,@(loop for slot-name in slot-names
                                        for initarg-name in initarg-names
                                        for slot-decoder in slot-decoders
                                        collect initarg-name
                                        if slot-decoder
                                        collect `(,slot-decoder ,slot-name)
                                        else collect slot-name))))))
      (c-export out make-function-name)
      (dolist (reader-name reader-names)
        (c-export out reader-name))
      (c-write out defclass-form)
      (c-write out make-defun-form))))

(define-grovel-syntax cstruct (struct-lisp-name struct-c-name &rest slots)
  (let ((documentation (when (stringp (car slots)) (pop slots))))
    (c-section-header out "cstruct" struct-lisp-name)
    (c-export out struct-lisp-name)
    (dolist (slot slots)
      (let ((slot-lisp-name (car slot)))
        (c-export out slot-lisp-name)))
    (c-format out "(cffi:defcstruct (")
    (c-print-symbol out struct-lisp-name t)
    (c-printf out " :size %llu)"
              (format nil "(long long unsigned) sizeof(~A)" struct-c-name))
    (when documentation
      (c-format out "~%  ~S" documentation))
    (dolist (slot slots)
      (destructuring-bind (slot-lisp-name slot-c-name &key type count)
          slot
        (c-format out "~%  (")
        (c-print-symbol out slot-lisp-name t)
        (c-format out " ")
        (etypecase type
          ((eql :auto)
           (format out "~&  SLOT_SIGNED_P(autotype_tmp, ~A, ~A~@[[0]~]);~@*~%~
                        ~&  type_name(output, autotype_tmp, sizeofslot(~A, ~A~@[[0]~]));~%"
                   struct-c-name
                   slot-c-name
                   (not (null count))))
          ((or cons symbol)
           (c-write out type))
          (string
           (c-format out "~A" type)))
        (etypecase count
          (null t)
          (integer
           (c-format out " :count ~D" count))
          ((eql :auto)
           (c-printf out " :count %llu"
                     (format nil "(long long unsigned) countofslot(~A, ~A)"
                             struct-c-name
                             slot-c-name)))
          ((or symbol string)
           (format out "~&#ifdef ~A~%" count)
           (c-printf out " :count %llu"
                     (format nil "(long long unsigned) (~A)" count))
           (format out "~&#endif~%")))
        (c-printf out " :offset %lli)"
                  (format nil "(long long signed) offsetof(~A, ~A)"
                          struct-c-name
                          slot-c-name))))
    (c-format out ")~%")
    (let ((size-of-constant-name
           (symbolicate '#:size-of- struct-lisp-name)))
      (c-export out size-of-constant-name)
      (c-format out "(cl:defconstant "
                size-of-constant-name struct-lisp-name)
      (c-print-symbol out size-of-constant-name)
      (c-format out " (cffi:foreign-type-size '(:struct ")
      (c-print-symbol out struct-lisp-name)
      (c-format out ")))~%"))))

(defmacro define-pseudo-cvar (str name type &key read-only)
  (let ((c-parse (let ((*read-eval* nil)
                       (*readtable* (copy-readtable nil)))
                   (setf (readtable-case *readtable*) :preserve)
                   (read-from-string str))))
    (typecase c-parse
      (symbol `(cffi:defcvar (,(symbol-name c-parse) ,name
                               :read-only ,read-only)
                   ,type))
      (list (unless (and (= (length c-parse) 2)
                         (null (second c-parse))
                         (symbolp (first c-parse))
                         (eql #\* (char (symbol-name (first c-parse)) 0)))
              (grovel-error "Unable to parse c-string ~s." str))
            (let ((func-name (symbolicate "%" name '#:-accessor)))
              `(progn
                 (declaim (inline ,func-name))
                 (cffi:defcfun (,(string-trim "*" (symbol-name (first c-parse)))
                                 ,func-name) :pointer)
                 (define-symbol-macro ,name
                     (cffi:mem-ref (,func-name) ',type)))))
      (t (grovel-error "Unable to parse c-string ~s." str)))))

(defun foreign-name-to-symbol (s)
  (intern (substitute #\- #\_ (string-upcase s))))

(defun choose-lisp-and-foreign-names (string-or-list)
  (etypecase string-or-list
    (string (values string-or-list (foreign-name-to-symbol string-or-list)))
    (list (destructuring-bind (fname lname &rest args) string-or-list
            (declare (ignore args))
            (assert (and (stringp fname) (symbolp lname)))
            (values fname lname)))))

(define-grovel-syntax cvar (name type &key read-only)
  (multiple-value-bind (c-name lisp-name)
      (choose-lisp-and-foreign-names name)
    (c-section-header out "cvar" lisp-name)
    (c-export out lisp-name)
    (c-printf out "(cffi-grovel::define-pseudo-cvar \"%s\" "
              (format nil "indirect_stringify(~A)" c-name))
    (c-print-symbol out lisp-name t)
    (c-format out " ")
    (c-write out type)
    (when read-only
      (c-format out " :read-only t"))
    (c-format out ")~%")))

;;; FIXME: where would docs on enum elements go?
(define-grovel-syntax cenum (name &rest enum-list)
  (destructuring-bind (name &key base-type define-constants)
      (ensure-list name)
    (c-section-header out "cenum" name)
    (c-export out name)
    (c-format out "(cffi:defcenum (")
    (c-print-symbol out name t)
    (when base-type
      (c-printf out " ")
      (c-print-symbol out base-type t))
    (c-format out ")")
    (dolist (enum enum-list)
      (destructuring-bind ((lisp-name &rest c-names) &key documentation)
          enum
        (declare (ignore documentation))
        (check-type lisp-name keyword)
        (loop for c-name in c-names do
          (check-type c-name string)
          (c-format out "  (")
          (c-print-symbol out lisp-name)
          (c-format out " ")
          (c-print-integer-constant out c-name base-type)
          (c-format out ")~%"))))
    (c-format out ")~%")
    (when define-constants
      (define-constants-from-enum out enum-list))))

(define-grovel-syntax constantenum (name &rest enum-list)
  (destructuring-bind (name &key base-type define-constants)
      (ensure-list name)
    (c-section-header out "constantenum" name)
    (c-export out name)
    (c-format out "(cffi:defcenum (")
    (c-print-symbol out name t)
    (when base-type
      (c-printf out " ")
      (c-print-symbol out base-type t))
    (c-format out ")")
    (dolist (enum enum-list)
      (destructuring-bind ((lisp-name &rest c-names)
                           &key optional documentation) enum
        (declare (ignore documentation))
        (check-type lisp-name keyword)
        (c-format out "~%  (")
        (c-print-symbol out lisp-name)
        (loop for c-name in c-names do
          (check-type c-name string)
          (format out "~&#ifdef ~A~%" c-name)
          (c-format out " ")
          (c-print-integer-constant out c-name base-type)
          (format out "~&#else~%"))
        (unless optional
          (c-format out
                    "~%  #.(cl:progn ~
                           (cl:warn 'cffi-grovel:missing-definition :name '~A) ~
                           -1)"
                    lisp-name))
        (dotimes (i (length c-names))
          (format out "~&#endif~%"))
        (c-format out ")")))
    (c-format out ")~%")
    (when define-constants
      (define-constants-from-enum out enum-list))))

(defun define-constants-from-enum (out enum-list)
  (dolist (enum enum-list)
    (destructuring-bind ((lisp-name &rest c-names) &rest options)
        enum
      (%process-grovel-form
       'constant out
       `((,(intern (string lisp-name)) ,(car c-names))
         ,@options)))))

(defun convert-intmax-constant (constant base-type)
  "Convert the C CONSTANT to an integer of BASE-TYPE. The constant is
assumed to be an integer printed using the PRIiMAX printf(3) format
string."
  ;; | C Constant |  Type   | Return Value | Notes                                 |
  ;; |------------+---------+--------------+---------------------------------------|
  ;; |         -1 |  :int32 |           -1 |                                       |
  ;; | 0xffffffff |  :int32 |           -1 | CONSTANT may be a positive integer if |
  ;; |            |         |              | sizeof(intmax_t) > sizeof(int32_t)    |
  ;; | 0xffffffff | :uint32 |   4294967295 |                                       |
  ;; |         -1 | :uint32 |   4294967295 |                                       |
  ;; |------------+---------+--------------+---------------------------------------|
  (let* ((canonical-type (cffi::canonicalize-foreign-type base-type))
         (type-bits (* 8 (cffi:foreign-type-size canonical-type)))
         (2^n (ash 1 type-bits)))
    (ecase canonical-type
      ((:unsigned-char :unsigned-short :unsigned-int
        :unsigned-long :unsigned-long-long)
       (mod constant 2^n))
      ((:char :short :int :long :long-long)
       (let ((v (mod constant 2^n)))
         (if (logbitp (1- type-bits) v)
             (- (mask-field (byte (1- type-bits) 0) v)
                (ash 1 (1- type-bits)))
             v))))))

(defun foreign-type-to-printf-specification (type)
  "Return the printf specification associated with the foreign type TYPE."
  (ecase (cffi::canonicalize-foreign-type type)
    (:char               "\"%hhd\"")
    (:unsigned-char      "\"%hhu\"")
    (:short              "\"%hd\"")
    (:unsigned-short     "\"%hu\"")
    (:int                "\"%d\"")
    (:unsigned-int       "\"%u\"")
    (:long               "\"%ld\"")
    (:unsigned-long      "\"%lu\"")
    (:long-long          "\"%lld\"")
    (:unsigned-long-long "\"%llu\"")))

;; Defines a bitfield, with elements specified as ((LISP-NAME C-NAME)
;; &key DOCUMENTATION).  NAME-AND-OPTS can be either a symbol as name,
;; or a list (NAME &key BASE-TYPE).
(define-grovel-syntax bitfield (name-and-opts &rest masks)
  (destructuring-bind (name &key base-type)
      (ensure-list name-and-opts)
    (c-section-header out "bitfield" name)
    (c-export out name)
    (c-format out "(cffi:defbitfield (")
    (c-print-symbol out name t)
    (when base-type
      (c-printf out " ")
      (c-print-symbol out base-type t))
    (c-format out ")")
    (dolist (mask masks)
      (destructuring-bind ((lisp-name &rest c-names)
                           &key optional documentation) mask
        (declare (ignore documentation))
        (check-type lisp-name symbol)
        (c-format out "~%  (")
        (c-print-symbol out lisp-name)
        (c-format out " ")
        (dolist (c-name c-names)
          (check-type c-name string)
          (format out "~&#ifdef ~A~%" c-name)
          (format out "~&  fprintf(output, ~A, ~A);~%"
                  (foreign-type-to-printf-specification (or base-type :int))
                  c-name)
          (format out "~&#else~%"))
        (unless optional
          (c-format out
                    "~%  #.(cl:progn ~
                           (cl:warn 'cffi-grovel:missing-definition :name '~A) ~
                           -1)"
                    lisp-name))
        (dotimes (i (length c-names))
          (format out "~&#endif~%"))
        (c-format out ")")))
    (c-format out ")~%")))


;;;# Wrapper Generation
;;;
;;; Here we generate a C file from a s-exp specification but instead
;;; of compiling and running it, we compile it as a shared library
;;; that can be subsequently loaded with LOAD-FOREIGN-LIBRARY.
;;;
;;; Useful to get at macro functionality, errno, system calls,
;;; functions that handle structures by value, etc...
;;;
;;; Matching CFFI bindings are generated along with said C file.

(defun process-wrapper-form (out form)
  (%process-wrapper-form (form-kind form) out (cdr form)))

;;; The various operators push Lisp forms onto this list which will be
;;; written out by PROCESS-WRAPPER-FILE once everything is processed.
(defvar *lisp-forms*)

(defun generate-c-lib-file (input-file output-defaults)
  (let ((*lisp-forms* nil)
        (c-file (make-c-file-name output-defaults "__wrapper")))
    (with-open-file (out c-file :direction :output :if-exists :supersede)
      (with-open-file (in input-file :direction :input)
        (write-string *header* out)
        (loop for form = (read in nil nil) while form
              do (process-wrapper-form out form))))
    (values c-file (nreverse *lisp-forms*))))

(defun make-soname (lib-soname output-defaults)
  (make-pathname :name lib-soname
                 :defaults output-defaults))

(defun generate-bindings-file (lib-file lib-soname lisp-forms output-defaults)
  (with-standard-io-syntax
    (let ((lisp-file (tmp-lisp-file-name output-defaults))
          (*print-readably* nil)
          (*print-escape* t))
      (with-open-file (out lisp-file :direction :output :if-exists :supersede)
        (format out ";;;; This file was automatically generated by cffi-grovel.~%~
                   ;;;; Do not edit by hand.~%")
        (let ((*package* (find-package '#:cl))
              (named-library-name
                (let ((*package* (find-package :keyword))
                      (*read-eval* nil))
                  (read-from-string lib-soname))))
          (pprint `(progn
                     (cffi:define-foreign-library
                         (,named-library-name
                          :type :grovel-wrapper
                          :search-path ,(directory-namestring lib-file))
                       (t ,(namestring (make-so-file-name lib-soname))))
                     (cffi:use-foreign-library ,named-library-name))
                  out)
          (fresh-line out))
        (dolist (form lisp-forms)
          (print form out))
        (terpri out))
      lisp-file)))

(defun cc-include-grovel-argument ()
  (format nil "-I~A" (truename (system-source-directory :cffi-grovel))))

;;; *PACKAGE* is rebound so that the IN-PACKAGE form can set it during
;;; *the extent of a given wrapper file.
(defun process-wrapper-file (input-file
                             &key
                               (output-defaults (make-pathname :defaults input-file :type "processed"))
                               lib-soname)
  (with-standard-io-syntax
    (multiple-value-bind (c-file lisp-forms)
        (generate-c-lib-file input-file output-defaults)
    (let ((lib-file (make-so-file-name (make-soname lib-soname output-defaults)))
          (o-file (make-o-file-name output-defaults "__wrapper")))
        (cc-compile o-file (list (cc-include-grovel-argument) c-file))
        (link-shared-library lib-file (list o-file))
        ;; FIXME: hardcoded library path.
        (values (generate-bindings-file lib-file lib-soname lisp-forms output-defaults)
                lib-file)))))

(defgeneric %process-wrapper-form (name out arguments)
  (:method (name out arguments)
    (declare (ignore out arguments))
    (grovel-error "Unknown Grovel syntax: ~S" name)))

;;; OUT is lexically bound to the output stream within BODY.
(defmacro define-wrapper-syntax (name lambda-list &body body)
  (with-unique-names (name-var args)
    `(defmethod %process-wrapper-form ((,name-var (eql ',name)) out ,args)
       (declare (ignorable out))
       (destructuring-bind ,lambda-list ,args
         ,@body))))

(define-wrapper-syntax progn (&rest forms)
  (dolist (form forms)
    (process-wrapper-form out form)))

(define-wrapper-syntax in-package (name)
  (assert (find-package name) (name)
          "Wrapper file specified (in-package ~s)~%~
           however that does not name a known package."
          name)
  (setq *package* (find-package name))
  (push `(in-package ,name) *lisp-forms*))

(define-wrapper-syntax c (&rest strings)
  (dolist (string strings)
    (write-line string out)))

(define-wrapper-syntax flag (&rest flags)
  (unionf *cc-flags* (parse-command-flags-list flags)
          :test #'string=))

(define-wrapper-syntax proclaim (&rest proclamations)
  (push `(proclaim ,@proclamations) *lisp-forms*))

(define-wrapper-syntax declaim (&rest declamations)
  (push `(declaim ,@declamations) *lisp-forms*))

(define-wrapper-syntax define (name &optional value)
  (format out "#define ~A~@[ ~A~]~%" name value))

(define-wrapper-syntax include (&rest includes)
  (format out "~{#include <~A>~%~}" includes))

;;; FIXME: this function is not complete.  Should probably follow
;;; typedefs?  Should definitely understand pointer types.
(defun c-type-name (typespec)
  (let ((spec (ensure-list typespec)))
    (if (stringp (car spec))
        (car spec)
        (case (car spec)
          ((:uchar :unsigned-char) "unsigned char")
          ((:unsigned-short :ushort) "unsigned short")
          ((:unsigned-int :uint) "unsigned int")
          ((:unsigned-long :ulong) "unsigned long")
          ((:long-long :llong) "long long")
          ((:unsigned-long-long :ullong) "unsigned long long")
          (:pointer "void*")
          (:string "char*")
          (t (cffi::foreign-name (car spec) nil))))))

(defun cffi-type (typespec)
  (if (and (listp typespec) (stringp (car typespec)))
      (second typespec)
      typespec))

(defun symbol* (s)
  (check-type s (and symbol (not null)))
  s)

(define-wrapper-syntax defwrapper (name-and-options rettype &rest args)
  (multiple-value-bind (lisp-name foreign-name options)
      (cffi::parse-name-and-options name-and-options)
    (let* ((foreign-name-wrap (strcat foreign-name "_cffi_wrap"))
           (fargs (mapcar (lambda (arg)
                            (list (c-type-name (second arg))
                                  (cffi::foreign-name (first arg) nil)))
                          args))
           (fargnames (mapcar #'second fargs)))
      ;; output C code
      (format out "~A ~A" (c-type-name rettype) foreign-name-wrap)
      (format out "(~{~{~A ~A~}~^, ~})~%" fargs)
      (format out "{~%  return ~A(~{~A~^, ~});~%}~%~%" foreign-name fargnames)
      ;; matching bindings
      (push `(cffi:defcfun (,foreign-name-wrap ,lisp-name ,@options)
                 ,(cffi-type rettype)
               ,@(mapcar (lambda (arg)
                           (list (symbol* (first arg))
                                 (cffi-type (second arg))))
                         args))
            *lisp-forms*))))

(define-wrapper-syntax defwrapper* (name-and-options rettype args &rest c-lines)
  ;; output C code
  (multiple-value-bind (lisp-name foreign-name options)
      (cffi::parse-name-and-options name-and-options)
    (let ((foreign-name-wrap (strcat foreign-name "_cffi_wrap"))
          (fargs (mapcar (lambda (arg)
                           (list (c-type-name (second arg))
                                 (cffi::foreign-name (first arg) nil)))
                         args)))
      (format out "~A ~A" (c-type-name rettype)
              foreign-name-wrap)
      (format out "(~{~{~A ~A~}~^, ~})~%" fargs)
      (format out "{~%~{  ~A~%~}}~%~%" c-lines)
      ;; matching bindings
      (push `(cffi:defcfun (,foreign-name-wrap ,lisp-name ,@options)
                 ,(cffi-type rettype)
               ,@(mapcar (lambda (arg)
                           (list (symbol* (first arg))
                                 (cffi-type (second arg))))
                         args))
            *lisp-forms*))))
