import Elle.ClosedPredicate
import Grade.Show

/-!
# The minimal histories of D9 and D10 (REPORT.md), Elle as written and fixed

Each is checked with the fix flags off (Elle as written) and with the closed-predicate fixes on
(`cpFixed := true`: D9's `:w` in `ww-graph`, D10's `versions-after` and D11's `version<`), under
the default options (strict serializable) and under the model REPORT.md names for it.
-/

open Elle

namespace Grade.Cases

def initOp (i : Nat) (kv : List (Nat × Int)) (t : OpType) : Op :=
  { index := i, type := t, process := 0, f := .init, value := kv.map fun (k, v) => { f := .w, k, v := .int v } }

def txOp (i p : Nat) (t : OpType) (ms : List Mop) : Op := { index := i, type := t, process := p, value := ms }

/-- D9: init {0 0, 1 0}; T1 [[:w 1 1]]; T2 [[:r 1 1] [:r 0 nil]]. -/
def d9 : History := #[initOp 0 [(0, 0), (1, 0)] .invoke, initOp 1 [(0, 0), (1, 0)] .ok,
  txOp 2 1 .invoke [{ f := .w, k := 1, v := .int 1 }],
  txOp 3 1 .ok [{ f := .w, k := 1, v := .int 1 }],
  txOp 4 2 .invoke [{ f := .r, k := 1, v := .nil }, { f := .r, k := 0, v := .nil }],
  txOp 5 2 .ok [{ f := .r, k := 1, v := .int 1 }, { f := .r, k := 0, v := .nil }]]

/-- D10: init {0 0, 1 0}; T1 [[:delete 1]]; T2 [[:rp [:= 0] {}] [:r 1 nil]]. -/
def d10 : History := #[initOp 0 [(0, 0), (1, 0)] .invoke, initOp 1 [(0, 0), (1, 0)] .ok,
  txOp 2 1 .invoke [{ f := .delete, k := 1, v := .nil }],
  txOp 3 1 .ok [{ f := .delete, k := 1, v := .nil }],
  txOp 4 2 .invoke [{ f := .rp, k := 0, v := .nil, pred := .eq 0 }, { f := .r, k := 1, v := .nil }],
  txOp 5 2 .ok [{ f := .rp, k := 0, v := .kmap [], pred := .eq 0 }, { f := .r, k := 1, v := .nil }]]

def report (name : String) (h : History) (model : String) : IO Unit := do
  IO.println s!"== {name}\n{Show.ednHistory h}"
  for (label, opts) in [("default options (strict-serializable)", ({} : Opts)),
                        (s!"models [{model}]", { models := some [model] })] do
    IO.println s!"  {label}"
    IO.println s!"    as written: {Show.outcomeStr (ClosedPredicate.check opts h)}"
    IO.println s!"    fixed:      {Show.outcomeStr (ClosedPredicate.check { opts with cpFixed := true } h)}"

end Grade.Cases

def main : IO Unit := do
  Grade.Cases.report "D9" Grade.Cases.d9 "serializable"
  Grade.Cases.report "D10" Grade.Cases.d10 "snapshot-isolation"
