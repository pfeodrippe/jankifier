/-!
# Functions jank calls through lean-sys

Each `@[export name]` makes the function a C symbol `name`. Arguments and
results that are Lean objects (`String`, `Array` ...) are `lean_object*`,
reference counted; numbers like `UInt64` are plain C integers.
-/

/-- A greeting, built in Lean. -/
@[export lean_sys_example_greet]
def greet (name : String) : String :=
  s!"Hello, {name}, from Lean {Lean.versionString}!"

/-- The words of `s`, sorted, with Lean's `Array.qsort`. -/
@[export lean_sys_example_sort_words]
def sortWords (s : String) : String :=
  " ".intercalate (((s.splitOn " ").filter (· ≠ "")).toArray.qsort (· < ·)).toList

/-- 0 + 1 + ... + (n - 1), on unboxed 64-bit integers. -/
@[export lean_sys_example_sum_below]
def sumBelow (n : UInt64) : UInt64 := Id.run do
  let mut acc : UInt64 := 0
  for i in [0:n.toNat] do
    acc := acc + i.toUInt64
  return acc
