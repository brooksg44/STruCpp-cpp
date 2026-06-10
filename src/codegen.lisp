;;;; codegen.lisp --- C++17 emitter.  SCAFFOLD: milestone 2 work happens here.
;;;;
;;;; Planned shape (mirroring the TypeScript backend/codegen.ts):
;;;;   * one C++ class per FUNCTION_BLOCK/PROGRAM: inputs/outputs/locals as
;;;;     members, the body as an operator()() scan method
;;;;   * FUNCTIONs become free functions
;;;;   * IEC type mapping per the original's codegen-utils.ts
;;;;     (BOOL->bool, INT->int16_t, DINT->int32_t, REAL->float, TIME->...)
;;;;   * reuse the original's header-only C++ runtime (src/runtime/include/)
;;;;     verbatim for types, std functions, and std FBs

(in-package #:strucpp-cpp)

(defun compile-st (text &key (stream *standard-output*))
  "Compile ST source TEXT to C++17 on STREAM.  Not yet implemented; the
frontend (parsing to AST) already works via STRUCPP-CL:PARSE-ST."
  (declare (ignore stream))
  (let ((unit (parse-st text)))
    (error "C++ code generation is milestone 2; parsed ~D POU(s) successfully."
           (length (unit-pous unit)))))

(defun compile-st-file (pathname &key (stream *standard-output*))
  (compile-st (uiop:read-file-string pathname) :stream stream))
