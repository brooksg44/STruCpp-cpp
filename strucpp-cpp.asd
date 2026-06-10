;;;; strucpp-cpp.asd --- ST -> C++17 code generator over the strucpp-cl frontend.
;;;;
;;;; The lexer/parser/AST live in the sibling STruCpp-cl system (one frontend,
;;;; two backends).  This system adds the C++17 emitter, mirroring the
;;;; TypeScript original's backend/ (github.com/brooksg44/STruCpp).
;;;;
;;;; Both projects must live under a directory ASDF scans (e.g. ~/common-lisp/)
;;;; so the cross-project dependency resolves.

(asdf:defsystem "strucpp-cpp"
  :description "IEC 61131-3 Structured Text to C++17 compiler (backend for the strucpp-cl frontend)."
  :author "brooksg44 <brooksg44@gmail.com>"
  :license "GPL-3.0"
  :version "0.1.0"
  :depends-on ("strucpp-cl")
  :serial t
  :components ((:module "src"
                :components ((:file "package")
                             (:file "codegen")))))
