;;;; package.lisp --- Package for the C++17 backend.

(defpackage #:strucpp-cpp
  (:use #:cl)
  (:import-from #:strucpp-cl
                ;; AST readers the code generator walks
                #:unit #:unit-pous #:find-pou
                #:pou #:pou-kind #:pou-name #:pou-return-type #:pou-vars #:pou-body
                #:var-decl #:var-decl-name #:var-decl-var-class
                #:var-decl-type-name #:var-decl-init #:var-decl-address
                #:var-decl-constant-p
                #:parse-st #:parse-st-file #:st-error)
  (:documentation
   "C++17 code generator for the strucpp-cl Structured Text frontend.")
  (:export #:compile-st #:compile-st-file))
