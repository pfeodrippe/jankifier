import Grade.Gen
import Grade.Show
import Elle.ClosedPredicate
import ElleCP.ClosedPredicate

/-!
# The grade: the agents' `ElleCP.check` against `Elle.ClosedPredicate.check`

For seeds `0 .. N-1` (N from the first argument, default 2000), both checkers run with the
default options (`{}`: strict serializable; every fix flag off, so the reference is Elle as
written) on `Grade.Gen.history seed`. Two outcomes agree on the verdict when both threw, or both
give the same `:valid?` and anomaly types; they agree fully when every case (cycles and their
steps) is the same too. Exit code 0 when every verdict agrees.
-/

open Elle Grade

def main (args : List String) : IO UInt32 := do
  let n := (args.head? >>= String.toNat?).getD 2000
  let mut agree := 0
  let mut full := 0
  let mut verdictDiffs : List (Nat × History × Outcome × Outcome) := []
  let mut detailDiffs : List (Nat × History × Outcome × Outcome) := []
  let mut dist : List (String × Nat) := []
  let mut types : List (String × Nat) := []
  let mut asWrittenVsFixed := 0
  for seed in List.range n do
    let h := Gen.history seed
    let want := Elle.ClosedPredicate.check {} h
    let got := ElleCP.check {} h
    let kind := match want with
      | .thrown _ => "threw"
      | .result r => match r.valid with
        | .true_ => "valid" | .false_ => "invalid" | .unknown => "unknown"
    dist := amUpdate dist kind 0 (· + 1)
    if let .result r := want then
      for t in r.anomalyTypes do types := amUpdate types t 0 (· + 1)
    if Show.verdictKey (Elle.ClosedPredicate.check { cpFixed := true } h) != Show.verdictKey want then
      asWrittenVsFixed := asWrittenVsFixed + 1
    if Show.verdictKey want == Show.verdictKey got then
      agree := agree + 1
      if Show.detailKey want == Show.detailKey got then full := full + 1
      else if detailDiffs.length < 5 then detailDiffs := detailDiffs ++ [(seed, h, want, got)]
    else if verdictDiffs.length < 5 then verdictDiffs := verdictDiffs ++ [(seed, h, want, got)]
  IO.println s!"seeds: {n} (0 to {n - 1})"
  IO.println s!"Elle as written on them: {dist}"
  IO.println s!"anomaly types in its verdicts (seeds with each): {types.mergeSort fun a b => decide (a.1 ≤ b.1)}"
  IO.println s!"seeds where Elle as written and the fixed checker (cpFixed) differ in verdict: {asWrittenVsFixed}"
  IO.println s!"verdicts agreed: {agree}, disagreed: {n - agree}"
  IO.println s!"fully agreed (cases and steps too): {full}, verdict agreed but cases differ: {agree - full}"
  let printAll (title : String) (l : List (Nat × History × Outcome × Outcome)) : IO Unit := do
    unless l.isEmpty do
      IO.println s!"\n{title}"
      for (seed, h, want, got) in l do
        IO.println s!"\n--- seed {seed}\n{Show.ednHistory h}"
        IO.println s!"  Elle.ClosedPredicate.check: {Show.outcomeStr want}"
        IO.println s!"  ElleCP.check:               {Show.outcomeStr got}"
  printAll "first disagreeing verdicts:" verdictDiffs
  printAll "first histories with the same verdict but different cases:" detailDiffs
  return if agree == n then 0 else 1
