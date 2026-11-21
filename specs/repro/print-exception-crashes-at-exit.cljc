; RESULTS.md S1.
; After a program prints an exception (its stack trace), the process crashes with SIGSEGV when it
; exits, after everything ran. Run it as `jank run print-exception-crashes-at-exit.cljc; echo
; "exit code $?"`: expected 0, jank exits with 139. Without the pr-str of the exception it exits
; with 0; so does it when the program ends with _exit (skipping exit handlers).
#?(:jank (cpp/raw "#include <cstdio>"))
(println "the printed exception is" (count (pr-str (ex-info "boom" {}))) "characters long")
(println "expected exit code 0")
;; The crash comes before stdio's buffer is written out at exit, so flush it here (when stdout is
;; a pipe these lines would be lost).
#?(:jank (cpp/fflush cpp/stdout))
