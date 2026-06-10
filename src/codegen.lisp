;;;; codegen.lisp --- C++17 emitter over the strucpp-cl AST.
;;;;
;;;; Mirrors the TypeScript original's output conventions:
;;;;   * identifiers UPCASED; one C++ class per FUNCTION_BLOCK / PROGRAM with
;;;;     public IEC_* members, a constructor carrying declared initializers,
;;;;     and the body as  void operator()();
;;;;   * FUNCTIONs become free C++ functions returning by value, with the
;;;;     IEC return variable lowered to a local <NAME>_result
;;;;   * FB invocation lowers to input assignments, INST(), then => copies:
;;;;       T1.IN = ...; T1.PT = ...; T1(); Q = T1.Q;
;;;;   * TIME literals become int64 nanoseconds (T#500ms -> 500000000LL)
;;;;   * generated code compiles against the original's header-only runtime
;;;;     (vendored under runtime/include/): IEC_* types, std functions, TIME()
;;;;
;;;; Standard FBs (TON, CTU, R_TRIG, SR, ...) are not special-cased: their ST
;;;; sources (vendored under stdfb/, from the original's iec-standard-fb
;;;; library) are parsed and emitted alongside user code when referenced.

(in-package #:strucpp-cpp)

;;; ---------------------------------------------------------------------------
;;; Names and types
;;; ---------------------------------------------------------------------------

(defun cxx-name (name) (string-upcase name))

(defparameter *elementary-types*
  '("BOOL" "BYTE" "WORD" "DWORD" "LWORD"
    "SINT" "INT" "DINT" "LINT" "USINT" "UINT" "UDINT" "ULINT"
    "REAL" "LREAL" "TIME" "STRING"))

(defun elementary-p (type-name)
  (member (string-upcase type-name) *elementary-types* :test #'string=))

(defun cxx-type (type-name)
  "IEC type -> C++ type: IEC_INT etc. for elementary, the upcased class name
for FB instance types."
  (if (elementary-p type-name)
      (concatenate 'string "IEC_" (string-upcase type-name))
      (cxx-name type-name)))

;;; ---------------------------------------------------------------------------
;;; Standard-FB bundling
;;; ---------------------------------------------------------------------------

(defparameter *stdfb-files*
  '(("timer.st"          . ("TON" "TOF" "TP"))
    ("counter.st"        . ("CTU" "CTD" "CTUD"))
    ("edge_detection.st" . ("R_TRIG" "F_TRIG"))
    ("bistable.st"       . ("SR" "RS")))
  "Vendored ST sources of the IEC standard FBs and the names each provides.")

(defun %stdfb-dir ()
  (merge-pathnames "stdfb/" (asdf:system-source-directory "strucpp-cpp")))

(defun %stdfb-source-for (fb-name)
  (loop for (file . names) in *stdfb-files*
        when (member (string-upcase fb-name) names :test #'string=)
          do (return file)))

(defun bundle-std-fbs (unit)
  "Return the list of standard-FB POUs referenced by UNIT's variable
declarations (in dependency-safe order), parsed from the vendored sources."
  (let ((needed '()))
    (dolist (pou (unit-pous unit))
      (dolist (v (pou-vars pou))
        (let ((tn (var-decl-type-name v)))
          (when (and (not (elementary-p tn))
                     (not (find-pou unit tn))
                     (%stdfb-source-for tn))
            (pushnew (string-upcase tn) needed :test #'string=)))))
    (loop for (file . names) in *stdfb-files*
          for wanted = (intersection names needed :test #'string=)
          when wanted
            append (let ((lib (parse-st-file (merge-pathnames file (%stdfb-dir)))))
                     (remove-if-not (lambda (p)
                                      (member (string-upcase (pou-name p))
                                              wanted :test #'string=))
                                    (unit-pous lib))))))

;;; ---------------------------------------------------------------------------
;;; Emitter state
;;; ---------------------------------------------------------------------------

(defvar *pou-index* nil
  "Hash of upcased POU name -> POU for everything being emitted (user + std),
used to resolve positional FB arguments and function calls.")

(defvar *current-pou* nil)
(defvar *case-counter* 0)

(defun %index-pous (pous)
  (let ((h (make-hash-table :test 'equal)))
    (dolist (p pous h)
      (setf (gethash (string-upcase (pou-name p)) h) p))))

(defun %find-decl (pou name)
  (find name (pou-vars pou) :key #'var-decl-name :test #'string-equal))

(defun %pou-inputs (pou)
  (remove :input (pou-vars pou) :key #'var-decl-var-class :test-not #'eq))

(defun %function-result-var (pou)
  (concatenate 'string (cxx-name (pou-name pou)) "_result"))

;;; ---------------------------------------------------------------------------
;;; Expressions
;;;
;;; Precedence-aware emission: a child is parenthesized when it binds looser
;;; than its parent, or equally on the right of a left-associative operator.
;;; ---------------------------------------------------------------------------

(defparameter *cxx-ops*
  ;; ast-op -> (c++-spelling . precedence)
  '((:or . ("||" . 1)) (:and . ("&&" . 2))
    (:xor . ("!=" . 3)) (:eq . ("==" . 3)) (:ne . ("!=" . 3))
    (:lt . ("<" . 4)) (:le . ("<=" . 4)) (:gt . (">" . 4)) (:ge . (">=" . 4))
    (:plus . ("+" . 5)) (:minus . ("-" . 5))
    (:star . ("*" . 6)) (:slash . ("/" . 6)) (:mod . ("%" . 6))))

(defun expr-cxx (expr &optional (prec 0) right-side)
  "Render EXPR as a C++ expression string, parenthesizing relative to the
parent's precedence PREC."
  (etypecase expr
    (strucpp-cl::literal (literal-cxx expr))
    (strucpp-cl::var-ref (var-ref-cxx expr))
    (strucpp-cl::member-ref
     (format nil "~A.~A"
             (expr-cxx (strucpp-cl::member-ref-base expr) 8)
             (cxx-name (strucpp-cl::member-ref-name expr))))
    (strucpp-cl::unop
     (let ((s (format nil "~A~A"
                      (ecase (strucpp-cl::unop-op expr) (:not "!") (:minus "-"))
                      (expr-cxx (strucpp-cl::unop-operand expr) 7))))
       (if (> prec 7) (format nil "(~A)" s) s)))
    (strucpp-cl::binop
     (let ((op (strucpp-cl::binop-op expr)))
       (if (eq op :power)
           (format nil "EXPT(~A, ~A)"
                   (expr-cxx (strucpp-cl::binop-left expr))
                   (expr-cxx (strucpp-cl::binop-right expr)))
           (destructuring-bind (spelling . my-prec)
               (cdr (assoc op *cxx-ops*))
             (let ((s (format nil "~A ~A ~A"
                              (expr-cxx (strucpp-cl::binop-left expr) my-prec)
                              spelling
                              (expr-cxx (strucpp-cl::binop-right expr)
                                        my-prec t))))
               (if (or (> prec my-prec) (and right-side (= prec my-prec)))
                   (format nil "(~A)" s)
                   s))))))
    (strucpp-cl::call-expr (call-cxx expr))))

(defun var-ref-cxx (expr)
  (let ((name (cxx-name (strucpp-cl::var-ref-name expr))))
    ;; inside a FUNCTION, the IEC return variable reads as <NAME>_result
    (if (and *current-pou*
             (eq (pou-kind *current-pou*) :function)
             (string= name (cxx-name (pou-name *current-pou*))))
        (%function-result-var *current-pou*)
        name)))

(defun literal-cxx (expr)
  (let ((v (strucpp-cl::literal-value expr)))
    (ecase (strucpp-cl::literal-st-type expr)
      (:bool (if v "true" "false"))
      (:int (format nil "~D" v))
      (:real (let ((*read-default-float-format* 'double-float))
               (princ-to-string (float v 1d0))))
      (:time (format nil "~DLL" (* v 1000000)))   ; lexer ms -> runtime ns
      (:string (format nil "~S" v)))))

(defun call-cxx (expr)
  "A call in expression position: user FUNCTION or runtime std function.
Named arguments are reordered into the function's declared input order."
  (let* ((name (cxx-name (strucpp-cl::call-expr-name expr)))
         (args (strucpp-cl::call-expr-args expr))
         (pou (and *pou-index* (gethash name *pou-index*))))
    (format nil "~A(~{~A~^, ~})"
            name
            (mapcar (lambda (a) (expr-cxx (strucpp-cl::call-arg-value a)))
                    (if (and pou (some #'strucpp-cl::call-arg-name args))
                        (%order-args pou args)
                        args)))))

(defun %order-args (pou args)
  (loop for input in (%pou-inputs pou)
        for hit = (find (var-decl-name input) args
                        :key #'strucpp-cl::call-arg-name
                        :test #'string-equal)
        when hit collect hit))

;;; ---------------------------------------------------------------------------
;;; Statements
;;; ---------------------------------------------------------------------------

(defun emit-stmts (stmts out indent)
  (dolist (s stmts) (emit-stmt s out indent)))

(defun %ind (out indent fmt &rest args)
  (format out "~V@T" indent)
  (apply #'format out fmt args)
  (terpri out))

(defun emit-stmt (stmt out indent)
  (etypecase stmt
    (strucpp-cl::assign-stmt
     (%ind out indent "~A = ~A;"
           (expr-cxx (strucpp-cl::assign-stmt-target stmt))
           (expr-cxx (strucpp-cl::assign-stmt-value stmt))))
    (strucpp-cl::call-stmt (emit-call-stmt stmt out indent))
    (strucpp-cl::if-stmt
     (loop for (test . body) in (strucpp-cl::if-stmt-clauses stmt)
           for first = t then nil
           do (%ind out indent "~:[} else if~;if~] (~A) {"
                    first (expr-cxx test))
              (emit-stmts body out (+ indent 4)))
     (when (strucpp-cl::if-stmt-else-body stmt)
       (%ind out indent "} else {")
       (emit-stmts (strucpp-cl::if-stmt-else-body stmt) out (+ indent 4)))
     (%ind out indent "}"))
    (strucpp-cl::case-stmt (emit-case stmt out indent))
    (strucpp-cl::for-stmt
     (let* ((var (cxx-name (strucpp-cl::for-stmt-var stmt)))
            (from (expr-cxx (strucpp-cl::for-stmt-from stmt)))
            (to (expr-cxx (strucpp-cl::for-stmt-to stmt)))
            (by (strucpp-cl::for-stmt-by stmt))
            (down (and by (%negative-literal-p by))))
       (if by
           (%ind out indent "for (~A = ~A; ~A ~A ~A; ~A += ~A) {"
                 var from var (if down ">=" "<=") to var (expr-cxx by))
           (%ind out indent "for (~A = ~A; ~A <= ~A; ~A++) {"
                 var from var to var)))
     (emit-stmts (strucpp-cl::for-stmt-body stmt) out (+ indent 4))
     (%ind out indent "}"))
    (strucpp-cl::while-stmt
     (%ind out indent "while (~A) {" (expr-cxx (strucpp-cl::while-stmt-test stmt)))
     (emit-stmts (strucpp-cl::while-stmt-body stmt) out (+ indent 4))
     (%ind out indent "}"))
    (strucpp-cl::repeat-stmt
     (%ind out indent "do {")
     (emit-stmts (strucpp-cl::repeat-stmt-body stmt) out (+ indent 4))
     (%ind out indent "} while (!(~A));"
           (expr-cxx (strucpp-cl::repeat-stmt-until stmt))))
    (strucpp-cl::exit-stmt (%ind out indent "break;"))
    (strucpp-cl::continue-stmt (%ind out indent "continue;"))
    (strucpp-cl::return-stmt
     (if (eq (pou-kind *current-pou*) :function)
         (%ind out indent "return ~A;" (%function-result-var *current-pou*))
         (%ind out indent "return;")))))

(defun %negative-literal-p (expr)
  (or (and (strucpp-cl::literal-p expr)
           (numberp (strucpp-cl::literal-value expr))
           (minusp (strucpp-cl::literal-value expr)))
      (and (strucpp-cl::unop-p expr)
           (eq (strucpp-cl::unop-op expr) :minus)
           (strucpp-cl::literal-p (strucpp-cl::unop-operand expr)))))

(defun emit-call-stmt (stmt out indent)
  "FB invocation: assign inputs, call operator(), copy => outputs.  A call to
something that is not an instance variable falls through as a plain call."
  (let* ((call (strucpp-cl::call-stmt-call stmt))
         (name (strucpp-cl::call-expr-name call))
         (args (strucpp-cl::call-expr-args call))
         (decl (and *current-pou* (%find-decl *current-pou* name)))
         (fb (and decl (gethash (string-upcase (var-decl-type-name decl))
                                *pou-index*))))
    (cond
      (fb
       (let ((inst (cxx-name name))
             (inputs (%pou-inputs fb)))
         (loop for arg in args
               for i from 0
               unless (eq (strucpp-cl::call-arg-direction arg) :out)
                 do (%ind out indent "~A.~A = ~A;"
                          inst
                          (cxx-name (or (strucpp-cl::call-arg-name arg)
                                        (var-decl-name (nth i inputs))))
                          (expr-cxx (strucpp-cl::call-arg-value arg))))
         (%ind out indent "~A();" inst)
         (loop for arg in args
               when (eq (strucpp-cl::call-arg-direction arg) :out)
                 do (%ind out indent "~A = ~A.~A;"
                          (expr-cxx (strucpp-cl::call-arg-value arg))
                          inst (cxx-name (strucpp-cl::call-arg-name arg))))))
      (t (%ind out indent "~A;" (call-cxx call))))))

(defun emit-case (stmt out indent)
  "CASE lowers to an if/else-if chain on a temporary (portable across range
labels, and EXIT inside a branch still breaks the enclosing loop)."
  (let ((tmp (format nil "__case_~D" (incf *case-counter*))))
    (%ind out indent "{")
    (let ((indent (+ indent 4)))
      (%ind out indent "const auto ~A = ~A;"
            tmp (expr-cxx (strucpp-cl::case-stmt-expr stmt)))
      (loop for (labels . body) in (strucpp-cl::case-stmt-branches stmt)
            for first = t then nil
            do (%ind out indent "~:[} else if~;if~] (~A) {"
                     first (%case-test tmp labels))
               (emit-stmts body out (+ indent 4)))
      (when (strucpp-cl::case-stmt-else-body stmt)
        (%ind out indent "} else {")
        (emit-stmts (strucpp-cl::case-stmt-else-body stmt) out (+ indent 4)))
      (%ind out indent "}"))
    (%ind out indent "}")))

(defun %case-test (tmp labels)
  (format nil "~{~A~^ || ~}"
          (mapcar (lambda (l)
                    (cond ((consp l)
                           (format nil "(~A >= ~A && ~A <= ~A)"
                                   tmp (%case-label-cxx (car l))
                                   tmp (%case-label-cxx (cdr l))))
                          (t (format nil "~A == ~A" tmp (%case-label-cxx l)))))
                  labels)))

(defun %case-label-cxx (l)
  (if (stringp l) (cxx-name l) (format nil "~D" l)))

;;; ---------------------------------------------------------------------------
;;; POU emission
;;; ---------------------------------------------------------------------------

(defun emit-class-header (pou out)
  (format out "class ~A {~%public:~%" (cxx-name (pou-name pou)))
  (dolist (v (pou-vars pou))
    (format out "    ~A ~A;~A~%"
            (cxx-type (var-decl-type-name v))
            (cxx-name (var-decl-name v))
            (if (var-decl-address v)
                (format nil "  // AT ~A" (var-decl-address v))
                "")))
  (format out "~%    // Constructor~%    ~A();~%" (cxx-name (pou-name pou)))
  (format out "~%    // Scan cycle body~%    void operator()();~%")
  (format out "};~%"))

(defun emit-class-source (pou out)
  (let ((name (cxx-name (pou-name pou)))
        (inits (remove-if-not #'var-decl-init (pou-vars pou))))
    (format out "~A::~A()~@[ : ~{~A~^, ~}~] {}~%~%"
            name name
            (when inits
              (mapcar (lambda (v)
                        (format nil "~A(~A)"
                                (cxx-name (var-decl-name v))
                                (expr-cxx (var-decl-init v))))
                      inits)))
    (format out "void ~A::operator()() {~%" name)
    (let ((*current-pou* pou))
      (emit-stmts (pou-body pou) out 4))
    (format out "}~%")))

(defun %function-signature (pou)
  (format nil "~A ~A(~{~A~^, ~})"
          (cxx-type (or (pou-return-type pou) "INT"))
          (cxx-name (pou-name pou))
          (mapcar (lambda (v)
                    (format nil "~A ~A"
                            (cxx-type (var-decl-type-name v))
                            (cxx-name (var-decl-name v))))
                  (%pou-inputs pou))))

(defun emit-function-source (pou out)
  (format out "~A {~%" (%function-signature pou))
  (format out "    ~A ~A{};~%"
          (cxx-type (or (pou-return-type pou) "INT"))
          (%function-result-var pou))
  (dolist (v (pou-vars pou))
    (unless (eq (var-decl-var-class v) :input)
      (format out "    ~A ~A~@[ = ~A~];~%"
              (cxx-type (var-decl-type-name v))
              (cxx-name (var-decl-name v))
              (and (var-decl-init v) (expr-cxx (var-decl-init v))))))
  (let ((*current-pou* pou))
    (emit-stmts (pou-body pou) out 4))
  (format out "    return ~A;~%}~%" (%function-result-var pou)))

;;; ---------------------------------------------------------------------------
;;; Entry points
;;; ---------------------------------------------------------------------------

(defun compile-st (text &key (name "program"))
  "Compile ST source TEXT.  Returns (values HEADER-STRING SOURCE-STRING):
the contents of NAME.hpp and NAME.cpp.  Referenced standard FBs are bundled
into the output from their vendored ST sources."
  (let* ((unit (parse-st text))
         (std (bundle-std-fbs unit))
         (pous (append std (unit-pous unit)))
         (*pou-index* (%index-pous pous))
         (*case-counter* 0)
         (classes (remove :function pous :key #'pou-kind))
         (functions (remove :function pous :key #'pou-kind :test-not #'eq)))
    (values
     (with-output-to-string (h)
       (format h "// Generated by strucpp-cpp -- do not edit~%")
       (format h "#pragma once~%~%#include \"iec_std_lib.hpp\"~%~%")
       (format h "using namespace strucpp;  // Runtime types~%~%")
       (dolist (f functions)
         (format h "~A;~%" (%function-signature f)))
       (when functions (terpri h))
       (loop for c in classes
             do (emit-class-header c h)
                (terpri h)))
     (with-output-to-string (s)
       (format s "// Generated by strucpp-cpp -- do not edit~%")
       (format s "#include \"~A.hpp\"~%~%" name)
       (dolist (f functions)
         (emit-function-source f s)
         (terpri s))
       (loop for c in classes
             do (emit-class-source c s)
                (terpri s))))))

(defun compile-st-file (pathname &key (output-dir (uiop:pathname-directory-pathname
                                                   pathname)))
  "Compile the ST file at PATHNAME to NAME.hpp/NAME.cpp next to it (or under
OUTPUT-DIR).  Returns the two output pathnames."
  (let ((name (pathname-name pathname)))
    (multiple-value-bind (hpp cpp)
        (compile-st (uiop:read-file-string pathname) :name name)
      (let ((hpp-path (merge-pathnames (format nil "~A.hpp" name) output-dir))
            (cpp-path (merge-pathnames (format nil "~A.cpp" name) output-dir)))
        (with-open-file (out hpp-path :direction :output :if-exists :supersede)
          (write-string hpp out))
        (with-open-file (out cpp-path :direction :output :if-exists :supersede)
          (write-string cpp out))
        (values hpp-path cpp-path)))))
