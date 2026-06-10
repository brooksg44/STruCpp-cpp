;;;; tests.lisp --- FiveAM suite.   Run with:  (asdf:test-system "strucpp-cpp")
;;;;
;;;; Two layers:
;;;;   1. Golden checks: the generated C++ contains the same landmarks the
;;;;      TypeScript original's tests assert (class NAME, IEC_INT members,
;;;;      void NAME::operator()(), FB-call lowering).
;;;;   2. End to end: generate C++ for the shipped examples, compile it with
;;;;      the system C++ compiler against the vendored runtime headers, RUN
;;;;      the binary, and assert on its output.  Skipped when no compiler.

(defpackage #:strucpp-cpp/tests
  (:use #:cl #:fiveam #:strucpp-cpp))

(in-package #:strucpp-cpp/tests)

(def-suite strucpp-cpp :description "strucpp-cpp emitter suite.")
(in-suite strucpp-cpp)

(defun system-dir ()
  (asdf:system-source-directory "strucpp-cpp"))

(defun example-text (name)
  (uiop:read-file-string
   (merge-pathnames (format nil "examples/~A" name) (system-dir))))

(defun emit (text &key (name "test"))
  (multiple-value-list (compile-st text :name name)))

(defun has (needle haystack)
  (and (search needle haystack) t))

;;; ---------------------------------------------------------------------------
;;; Golden checks (mirroring the TypeScript codegen-fb tests)
;;; ---------------------------------------------------------------------------

(defparameter *adder* "FUNCTION_BLOCK Adder
VAR_INPUT a : INT; b : INT; END_VAR
VAR_OUTPUT result : INT; END_VAR
result := a + b;
END_FUNCTION_BLOCK")

(test fb-becomes-class-with-iec-members
  (destructuring-bind (hpp cpp) (emit *adder*)
    (is (has "class ADDER {" hpp))
    (is (has "public:" hpp))
    (is (has "IEC_INT A;" hpp))
    (is (has "IEC_INT B;" hpp))
    (is (has "IEC_INT RESULT;" hpp))
    (is (has "void operator()();" hpp))
    (is (has "ADDER::ADDER()" cpp))
    (is (has "void ADDER::operator()()" cpp))
    (is (has "RESULT = A + B;" cpp))))

(test declared-initializers-land-in-constructor
  (destructuring-bind (hpp cpp)
      (emit "FUNCTION_BLOCK F
VAR x : INT := 100; r : REAL := 1.5; t : TIME := T#500ms; END_VAR
x := x;
END_FUNCTION_BLOCK")
    (declare (ignore hpp))
    (is (has "X(100)" cpp))
    (is (has "R(1.5)" cpp))
    (is (has "T(500000000LL)" cpp))))    ; ms -> ns

(test fb-call-lowering
  (destructuring-bind (hpp cpp)
      (emit "FUNCTION_BLOCK MyFb
VAR_INPUT a : INT; b : INT; END_VAR
VAR_OUTPUT result : INT; END_VAR
result := a + b;
END_FUNCTION_BLOCK
PROGRAM P
VAR add : MyFb; sum : INT; END_VAR
add(a := 5, b := 3, result => sum);
END_PROGRAM")
    (is (has "MYFB ADD;" hpp))
    (is (has "ADD.A = 5;" cpp))
    (is (has "ADD.B = 3;" cpp))
    (is (has "ADD();" cpp))
    (is (has "SUM = ADD.RESULT;" cpp))))

(test function-lowering-with-result-variable
  (destructuring-bind (hpp cpp)
      (emit "FUNCTION Add3 : DINT
VAR_INPUT a : DINT; b : DINT; c : DINT; END_VAR
Add3 := a + b + c;
END_FUNCTION")
    (is (has "IEC_DINT ADD3(IEC_DINT A, IEC_DINT B, IEC_DINT C);" hpp))
    (is (has "ADD3_result = A + B + C;" cpp))
    (is (has "return ADD3_result;" cpp))))

(test control-flow-shapes
  (destructuring-bind (hpp cpp)
      (emit "PROGRAM P
VAR i : INT; x : INT; END_VAR
FOR i := 1 TO 10 DO x := x + i; END_FOR;
FOR i := 10 TO 1 BY -2 DO x := x - i; END_FOR;
WHILE x > 0 DO x := x - 1; END_WHILE;
REPEAT x := x + 1; UNTIL x >= 5 END_REPEAT;
CASE x OF
1: x := 10;
4..6: x := 30;
ELSE x := 99;
END_CASE;
END_PROGRAM")
    (declare (ignore hpp))
    (is (has "for (I = 1; I <= 10; I++) {" cpp))
    (is (has "for (I = 10; I >= 1; I += -2) {" cpp))
    (is (has "while (X > 0) {" cpp))
    (is (has "} while (!(X >= 5));" cpp))
    (is (has "__case_1 == 1" cpp))
    (is (has "(__case_1 >= 4 && __case_1 <= 6)" cpp))))

(test std-fbs-bundled-when-referenced
  (destructuring-bind (hpp cpp) (emit (example-text "blink.st") :name "blink")
    (is (has "class TON {" hpp))
    (is (has "class BLINK {" hpp))
    (is (has "TON TIMER;" hpp))
    (is (has "TIMER.IN = !TIMER.Q;" cpp))
    (is (has "TIMER();" cpp))
    ;; TON's own body came along, reading the runtime's cycle clock
    (is (has "void TON::operator()()" cpp))
    (is (has "CURRENT_TIME = TIME();" cpp))))

(test precedence-parenthesization
  (destructuring-bind (hpp cpp)
      (emit "PROGRAM P
VAR x : INT; b : BOOL; END_VAR
x := 2 + 3 * 4;
x := (2 + 3) * 4;
x := 10 - (4 - 2);
b := b OR b AND b;
x := 2 ** 3;
END_PROGRAM")
    (declare (ignore hpp))
    (is (has "X = 2 + 3 * 4;" cpp))
    (is (has "X = (2 + 3) * 4;" cpp))
    (is (has "X = 10 - (4 - 2);" cpp))
    (is (has "B = B || B && B;" cpp))
    (is (has "X = EXPT(2, 3);" cpp))))

;;; ---------------------------------------------------------------------------
;;; End to end: compile the generated C++ and run it
;;; ---------------------------------------------------------------------------

(defparameter *cxx*
  (or (uiop:getenv "CXX")
      (and (uiop:run-program '("which" "c++") :ignore-error-status t
                             :output '(:string :stripped t))
           "c++"))
  "The system C++ compiler, or NIL to skip the run tests.")

(defun build-and-run (st-name main-cpp)
  "Compile examples/ST-NAME with the emitter, build it together with MAIN-CPP
against the vendored runtime, run the binary, and return its stdout."
  (let* ((dir (merge-pathnames (format nil "strucpp-e2e-~A/" (pathname-name st-name))
                               (uiop:temporary-directory)))
         (name (pathname-name st-name)))
    (ensure-directories-exist dir)
    (compile-st-file (merge-pathnames (format nil "examples/~A" st-name)
                                      (system-dir))
                     :output-dir dir)
    (with-open-file (out (merge-pathnames "main.cpp" dir)
                         :direction :output :if-exists :supersede)
      (write-string main-cpp out))
    (uiop:run-program
     (list *cxx* "-std=c++17" "-w"
           (format nil "-I~A" (namestring (merge-pathnames "runtime/include/"
                                                           (system-dir))))
           (format nil "-I~A" (namestring dir))
           (namestring (merge-pathnames (format nil "~A.cpp" name) dir))
           (namestring (merge-pathnames "main.cpp" dir))
           "-o" (namestring (merge-pathnames "a.out" dir)))
     :error-output :string)
    (uiop:run-program (list (namestring (merge-pathnames "a.out" dir)))
                      :output '(:string :stripped t))))

(test e2e-counter-compiles-and-runs
  (if (not *cxx*)
      (skip "no C++ compiler found")
      (is (string= "count=3 after_reset=0 atmin=1"
                   (build-and-run "counter.st" "
#include \"counter.hpp\"
#include <cstdio>
int main() {
    COUNTER c;
    for (int i = 0; i < 3; i++) {
        c.COUNTUP = true;  c();
        c.COUNTUP = false; c();
    }
    std::printf(\"count=%d \", (int)c.COUNT);
    c.RESET = true; c();
    std::printf(\"after_reset=%d atmin=%d\", (int)c.COUNT, (int)c.ATMIN);
    return 0;
}")))))

(test e2e-motor-control-compiles-and-runs
  (if (not *cxx*)
      (skip "no C++ compiler found")
      (is (string= "stopped=0 running=1 latched=1 fault=0 tripped=1"
                   (build-and-run "motor_control.st" "
#include \"motor_control.hpp\"
#include <cstdio>
int main() {
    MOTORCONTROL m;
    m.EMERGENCYSTOP = true;            // NC input: TRUE = healthy
    m();
    std::printf(\"stopped=%d \", (int)m.MOTORCONTACTOR);
    m.STARTBUTTON = true; m();
    std::printf(\"running=%d \", (int)m.MOTORCONTACTOR);
    m.STARTBUTTON = false; m();
    std::printf(\"latched=%d \", (int)m.MOTORCONTACTOR);
    m.OVERLOADTRIP = true; m();
    std::printf(\"fault=%d tripped=%d\",
                (int)m.MOTORCONTACTOR, (int)m.FAULTLAMP);
    return 0;
}")))))

(test e2e-pid-compiles-and-runs
  (if (not *cxx*)
      (skip "no C++ compiler found")
      (is (string= "err=2.000 out=2.220"
                   (build-and-run "pid_controller.st" "
#include \"pid_controller.hpp\"
#include <cstdio>
int main() {
    PID_CONTROLLER p;
    p.SETPOINT = 10.0f;
    p.PROCESSVALUE = 8.0f;
    p();
    std::printf(\"err=%.3f out=%.3f\", (double)p.ERROR, (double)p.OUTPUT);
    return 0;
}")))))

(test e2e-blink-toggles-on-runtime-clock
  (if (not *cxx*)
      (skip "no C++ compiler found")
      (let ((out (build-and-run "blink.st" "
#include \"blink.hpp\"
#include <cstdio>
int main() {
    BLINK b;
    int changes = 0;
    bool prev = false;
    for (int i = 1; i <= 30; i++) {                 // 3s of 100ms cycles
        __CURRENT_TIME_NS = (int64_t)i * 100000000LL;
        b();
        bool out = b.OUTPUT;
        if (out != prev) { changes++; prev = out; }
    }
    std::printf(\"changes=%d\", changes);
    return 0;
}")))
        (is (<= 4 (parse-integer out :start (1+ (position #\= out))))))))
