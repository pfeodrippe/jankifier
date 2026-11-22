module
public import Veil

/-!
# jank's module loader and its compiled-module cache

A model of how jank 0.1 finds and loads a module, from its source (`.jank`) or
from a compiled object file (`.o`), and of the cache of object files that
`jank compile-module` writes. Code references are to jank `f3d82d654`
(`compiler+runtime/`), which is what the installed jank 0.1 was built from.

## What is modelled

- **Files.** Directories on the module path, in order (`tot.le d e`: `d` comes
  before `e`), holding sources and object files of modules. Each source has a
  version and an mtime; each object file records the source version it was
  compiled from, the directory of that source, and the version of each
  dependency it was compiled against (macros are expanded at compile time).
- **Processes.** A jank process (`proc`): a REPL / `jank run`, or a
  `jank compile-module`, each with its own module index and loaded modules.
  Two can be alive at once (a REPL, while another terminal compiles).
- **The index** (`loader::entries`, `loader_dynamic.cpp:181-366`): built when a
  process starts, by registering every file on the module path in order. A
  later registration of the same module and extension overwrites an earlier
  one (`register_entry`, `loader_dynamic.cpp:181`), so the *last* directory
  wins. The index is only rebuilt when a lookup misses (`find_module`,
  `loader_dynamic.cpp:514`).
- **`find`** (`loader_dynamic.cpp:545`): a module needs a source; it is loaded
  from its object file iff the indexed object file exists and
  `mtime(o) >= mtime(source)`, else from source.
- **`load_o`** (`loader_dynamic.cpp:780`): if the process already has the
  module's `jank_load_<module>` symbol (from an earlier object load), it calls
  that again instead of loading the object file.
- **Compiling** (`context_dynamic.cpp` `compile_module`, `write_module`): with
  `*compile-files*`, a module loaded *from source* writes its object file to the
  build directory; a module loaded from its object file writes nothing.
- **`require`**: dependencies load first; a loaded module isn't loaded again
  unless `:reload` (`clojure.core/load-lib`).

`fixed` turns on proposed fixes of jank, to check them before they're written:

- `m1`: an object file records the versions of the dependencies it was
  compiled against (their hashes, in jank), and `find` loads it only if those
  are the versions loaded now; otherwise the source loads (and, in a compile,
  writes a new object file).
- `m2`: `register_entry` keeps the first directory's entry of a module, as
  `loader.hpp` documents.
- `m3`: every lookup looks at the module's files again (as a miss does now),
  so a running process sees object files written after it started.
- `m4`: `find` checks that the indexed source still exists before reading its
  mtime; a module whose source is gone is reported as having no source.
- `m5`: `load_o` loads the object file it chose even when the process already
  has `jank_load_<module>` (the new object's symbol is looked up in its own
  handle), so a reload runs the new code.

Each load records what the loaded code prints in the conformance tests: the
module, the directory and version of the source its code came from, whether it
was compiled ahead of time (`*compile-files*` when its macros expanded), and the
version of each dependency's macros it was compiled against.

Not modelled: JARs (object files in JARs are ignored, `loader_dynamic.cpp:617`),
`.cljc` and `.cpp` modules, cyclic dependencies.
-/

-- The SMT solver's answers are turned into proofs which Lean's kernel checks.
set_option veil.smt.trust false

veil module ModuleCache

type modname
type dir
type proc
instantiate tot : TotalOrder dir
open TotalOrder

enum mode_t = { idle, running, compiling }
enum outcome = { nothing, fromSrc, fromObj, fsError, missingFile, noSource, notFound }
/- The proposed fixes (see above). -/
enum fix_t = { m1, m2, m3, m4, m5 }

/- `dep m d`: module `m` requires `d` (its `ns` form). -/
immutable relation dep : modname → modname → Bool
/- The directory `jank compile-module` writes object files to
(`<build-dir>/<binary version>`, which is on the module path). -/
immutable individual build : dir
/- Which expected property to check (see the end of the file); 0 checks only
the properties which hold. -/
immutable individual focus : Nat
immutable relation fixed : fix_t → Bool

/-! Files. A version of 0 means the file doesn't exist. -/
function srcVer : dir → modname → Nat
function srcTime : dir → modname → Nat
function objVer : dir → modname → Nat
function objSrcDir : dir → modname → dir
function objDepVer : dir → modname → modname → Nat
function objTime : dir → modname → Nat
/- mtimes come from this clock; every write ticks it. -/
individual clock : Nat
/- Every edit writes a new, unique source version. -/
individual nextVer : Nat

/-! Processes. -/
function mode : proc → mode_t
relation idxSrc : proc → dir → modname → Bool
relation idxObj : proc → dir → modname → Bool
relation loaded : proc → modname → Bool
function codeVer : proc → modname → Nat
function codeDir : proc → modname → dir
function codeDepVer : proc → modname → modname → Nat
/- The code behind the process's `jank_load_<module>` symbol: 0 if it has none. -/
function symVer : proc → modname → Nat
function symDir : proc → modname → dir
function symDepVer : proc → modname → modname → Nat

/-! The last load, as observed. -/
individual lastOutcome : outcome
individual lastProc : proc
individual lastModule : modname
individual lastDir : dir
individual lastVer : Nat
individual lastAot : Bool
function lastDepVer : modname → Nat
/- The version of the object file `find` chose for the last load (0: none). -/
individual lastObjVer : Nat
/- The directory of the source `find` chose for the last load, and whether no
file changed since that load (so the index and files are what it saw). -/
individual lastSrcDir : dir
individual lastLoadFresh : Bool

#gen_state

after_init {
  srcVer D M := 0
  srcTime D M := 0
  objVer D M := 0
  objTime D M := 0
  objDepVer D M N := 0
  clock := 0
  nextVer := 1
  mode P := idle
  idxSrc P D M := false
  idxObj P D M := false
  loaded P M := false
  codeVer P M := 0
  codeDepVer P M N := 0
  symVer P M := 0
  symDepVer P M N := 0
  lastOutcome := nothing
  lastVer := 0
  lastAot := false
  lastDepVer M := 0
  lastObjVer := 0
  lastLoadFresh := false
}

/-! ## Files -/

/- `jank compile-module` runs as one command (for a few seconds): while it
runs, nothing edits files, and no other process acts. -/
ghost relation noCompile := ∀ P, mode P ≠ compiling
ghost relation onlyCompiler (p : proc) := ∀ P, mode P = compiling → P = p

/- Write a new version of `m`'s source in `d`. Sources live in the user's
directories, not the build directory. -/
action editSrc (d : dir) (m : modname) {
  require noCompile
  require d ≠ build
  clock := clock + 1
  srcVer d m := nextVer
  srcTime d m := clock
  nextVer := nextVer + 1
  lastLoadFresh := false
}

action deleteSrc (d : dir) (m : modname) {
  require noCompile
  require srcVer d m ≠ 0
  srcVer d m := 0
  lastLoadFresh := false
}

action deleteObj (d : dir) (m : modname) {
  require noCompile
  require objVer d m ≠ 0
  objVer d m := 0
  lastLoadFresh := false
}

/- `touch` a source: it becomes the newest file. -/
action touchSrc (d : dir) (m : modname) {
  require noCompile
  require srcVer d m ≠ 0
  clock := clock + 1
  srcTime d m := clock
  lastLoadFresh := false
}

/- Give a source the same mtime as an object file (`touch -r`), which is where
`find`'s `>=` matters. -/
action tieSrcToObj (ds : dir) (dob : dir) (m : modname) {
  require noCompile
  require srcVer ds m ≠ 0 ∧ objVer dob m ≠ 0
  srcTime ds m := objTime dob m
  lastLoadFresh := false
}

/-! ## Processes -/

/- Building the index when the loader starts (`loader::loader`,
`register_module_path`): for each modname, the last directory with a source,
and the last with an object file. -/
procedure buildIndex (p : proc) {
  -- With the fix `m2`, the first directory.
  idxSrc p D M := decide (srcVer D M ≠ 0 ∧
                          ∀ E, srcVer E M ≠ 0 → ((¬ fixed m2 ∧ le E D) ∨ (fixed m2 ∧ le D E)))
  idxObj p D M := decide (objVer D M ≠ 0 ∧
                          ∀ E, objVer E M ≠ 0 → ((¬ fixed m2 ∧ le E D) ∨ (fixed m2 ∧ le D E)))
}

/- A lookup miss registers the module path again (`find_module`): entries of
modules with files now are overwritten, last directory wins; other entries
stay as they were, even if their files are gone. -/
procedure rescan (p : proc) {
  -- (Written as one formula: an `if` here trips Veil's VC generation.)
  idxSrc p D M := decide (((∃ E, srcVer E M ≠ 0) ∧ srcVer D M ≠ 0 ∧
                           ∀ E, srcVer E M ≠ 0 → ((¬ fixed m2 ∧ le E D) ∨ (fixed m2 ∧ le D E)))
                          ∨ (¬ (∃ E, srcVer E M ≠ 0) ∧ idxSrc p D M))
  idxObj p D M := decide (((∃ E, objVer E M ≠ 0) ∧ objVer D M ≠ 0 ∧
                           ∀ E, objVer E M ≠ 0 → ((¬ fixed m2 ∧ le E D) ∨ (fixed m2 ∧ le D E)))
                          ∨ (¬ (∃ E, objVer E M ≠ 0) ∧ idxObj p D M))
}

procedure startProc (p : proc) {
  loaded p M := false
  codeVer p M := 0
  symVer p M := 0
  buildIndex p
}

/- Start a REPL or `jank run`. -/
action startRun (p : proc) {
  require onlyCompiler p
  require mode p = idle
  mode p := running
  startProc p
}

/- Start `jank compile-module` (`*compile-files*` is true, output target
`object`). -/
action startCompile (p : proc) {
  require noCompile
  require mode p = idle
  mode p := compiling
  startProc p
}

action stop (p : proc) {
  require onlyCompiler p
  require mode p ≠ idle
  mode p := idle
}

/- Evaluating the source (`load_jank`). The module's macros expand against the
loaded versions of its dependencies; when compiling, its object file is written
to the build directory. -/
procedure loadSrc (p : proc) (m : modname) (ds : dir) {
  lastOutcome := fromSrc
  lastDir := ds
  lastVer := srcVer ds m
  lastAot := (mode p = compiling)
  lastDepVer D := if dep m D then codeVer p D else 0
  codeDepVer p m D := if dep m D then codeVer p D else 0
  codeVer p m := srcVer ds m
  codeDir p m := ds
  loaded p m := true
  if mode p = compiling then
    clock := clock + 1
    objVer build m := srcVer ds m
    objSrcDir build m := ds
    objDepVer build m D := if dep m D then codeVer p D else 0
    objTime build m := clock
}

/- Loading the object file (`load_o`). If the process already has
`jank_load_<m>`, that is called again and the object file isn't loaded (with
the fix `m5`, it is). -/
procedure loadObj (p : proc) (m : modname) (dob : dir) {
  lastOutcome := fromObj
  lastObjVer := objVer dob m
  lastAot := true
  if symVer p m = 0 ∨ fixed m5 then
    symVer p m := objVer dob m
    symDir p m := objSrcDir dob m
    symDepVer p m D := objDepVer dob m D
  lastVer := symVer p m
  lastDir := symDir p m
  lastDepVer D := symDepVer p m D
  codeVer p m := symVer p m
  codeDir p m := symDir p m
  codeDepVer p m D := symDepVer p m D
  loaded p m := true
}

/- `(require m)`, or `(require m :reload)` when `m` is loaded already: `find`
then load (`loader::load`). A failed load leaves `m` unloaded. `find` comes
first, so a module which can't be found fails before its dependencies load;
once found, its `ns` form loads them, which is why the successful paths
require them loaded. In a compile, these are the modules
`jank compile-module` loads. -/
action load (p : proc) (m : modname) {
  require onlyCompiler p
  require mode p ≠ idle
  -- `jank compile-module` loads each module once.
  require mode p = running ∨ ¬ loaded p m
  lastProc := p
  lastModule := m
  lastObjVer := 0
  lastDepVer D := 0
  -- With the fix `m3`, every lookup looks at the files again.
  if fixed m3 ∨ ¬ (∃ D, idxSrc p D m ∨ idxObj p D m) then
    rescan p
  lastLoadFresh := true
  if ¬ (∃ D, idxSrc p D m ∨ idxObj p D m) then
    lastOutcome := notFound
  else
    if ¬ (∃ D, idxSrc p D m) then
      lastOutcome := noSource
    else
      let ds :| idxSrc p ds m
      lastSrcDir := ds
      if (∃ D, idxObj p D m ∧ objVer D m ≠ 0) then
        let dob :| idxObj p dob m ∧ objVer dob m ≠ 0
        if srcVer ds m = 0 then
          -- `last_modified_at` on the missing source throws (with the fix
          -- `m4`, it isn't called: there's no source).
          if fixed m4 then
            lastOutcome := noSource
          else
            lastOutcome := fsError
        else
          -- Found: its `ns` form loads its dependencies first.
          require ∀ D, dep m D → loaded p D
          -- With the fix `m1`, the object file must also have been compiled
          -- against the loaded versions of the module's dependencies.
          if objTime dob m ≥ srcTime ds m ∧
             (¬ fixed m1 ∨ ∀ D, dep m D → objDepVer dob m D = codeVer p D) then
            loadObj p m dob
          else
            loadSrc p m ds
      else
        if srcVer ds m = 0 then
          -- `eval_file` of the missing source.
          lastOutcome := missingFile
        else
          require ∀ D, dep m D → loaded p D
          loadSrc p m ds
}

/-! ## Properties

The first two hold, and `#check_invariants` proves them for all instances.
The others are what users expect; each is checked on its own (`focus`); the
model checker's counterexamples are reproduced on jank by
`jank-specs.conformance.module-cache`. -/

/- A loaded module's dependencies are loaded. -/
safety [deps_loaded] loaded P M ∧ dep M D → loaded P D
/- A loaded module has code. -/
safety [loaded_has_code] loaded P M → codeVer P M ≠ 0

/- M1: an object file is only loaded if it was compiled against the versions
of its dependencies which are loaded. (Reloading a dependency in a REPL without
reloading its dependents is normal Clojure behaviour, and not what this is
about.) -/
safety [m1_object_matches_dependencies]
  focus = 1 → (lastOutcome = fromObj ∧ dep lastModule D → lastDepVer D = codeVer lastProc D)
/- M2: as `loader.hpp` documents, the first directory with a module wins: a
load uses its source. -/
safety [m2_first_match_wins]
  focus = 2 → (lastLoadFresh ∧ (lastOutcome = fromSrc ∨ lastOutcome = fromObj) →
    ∀ E, srcVer E lastModule ≠ 0 → le lastSrcDir E)
/- M3: a running process (REPL) sees the object files of the modules it
knows: a load's lookup knows the object files on disk. Both are stated about
loads (right after one, while no file has changed), not about the index, which
is a cache: right after another process writes a file, every index is out of
date, whatever the loader does. -/
safety [m3_index_sees_new_objects]
  focus = 3 → (lastLoadFresh ∧ mode lastProc = running ∧ (∃ D, objVer D lastModule ≠ 0) ∧
    (∃ E, idxSrc lastProc E lastModule) → ∃ E, idxObj lastProc E lastModule ∧ objVer E lastModule ≠ 0)
/- M4: a module whose source was deleted is reported as such, not as a
filesystem error. -/
safety [m4_deleted_source_reported] focus = 4 → lastOutcome ≠ fsError
/- M5: loading from an object file runs that object file's code. -/
safety [m5_load_runs_chosen_object]
  focus = 5 → (lastOutcome = fromObj → lastVer = lastObjVer)

-- Keeps the explicit-state searches finite.
state_constraint [bounded] clock ≤ 5 ∧ nextVer ≤ 4

#gen_spec

/- Every action can happen. -/
sat trace [can_load_from_source] {
  editSrc
  startRun
  load
  assert (lastOutcome = fromSrc)
}
sat trace [can_compile_and_load_object] {
  editSrc
  startCompile
  load
  stop
  startRun
  load
  assert (lastOutcome = fromObj)
}

/-! ## Model checking

Two modules, `lib` (0) and `app` (1), where `app` requires `lib`; directories
`a` (0) and `b` (1) on the module path, then the build directory (2); two
processes. -/

#model_check { modname := Fin 2, dir := Fin 3, proc := Fin 2 }
  { dep := fun m d => decide (m = 1 ∧ d = 0), build := 2, focus := 0,
    fixed := fun _ => false } (maxDepth := 7)

/- Each expected property, on its own: the first run fails the build unless
the model checker finds a violation; the second prints the counterexample
without failing it, for the conformance harness to read from the build log. -/

-- m1_object_matches_dependencies
#guard_msgs (drop error) in
#model_check { modname := Fin 2, dir := Fin 3, proc := Fin 2 }
  { dep := fun m d => decide (m = 1 ∧ d = 0), build := 2, focus := 1,
    fixed := fun _ => false } (sequential := true)

set_option veil.violationIsError false in
#model_check { modname := Fin 2, dir := Fin 3, proc := Fin 2 }
  { dep := fun m d => decide (m = 1 ∧ d = 0), build := 2, focus := 1,
    fixed := fun _ => false } (sequential := true)

-- m2_first_match_wins
#guard_msgs (drop error) in
#model_check { modname := Fin 2, dir := Fin 3, proc := Fin 2 }
  { dep := fun m d => decide (m = 1 ∧ d = 0), build := 2, focus := 2,
    fixed := fun _ => false } (sequential := true)

set_option veil.violationIsError false in
#model_check { modname := Fin 2, dir := Fin 3, proc := Fin 2 }
  { dep := fun m d => decide (m = 1 ∧ d = 0), build := 2, focus := 2,
    fixed := fun _ => false } (sequential := true)

-- m3_index_sees_new_objects
#guard_msgs (drop error) in
#model_check { modname := Fin 2, dir := Fin 3, proc := Fin 2 }
  { dep := fun m d => decide (m = 1 ∧ d = 0), build := 2, focus := 3,
    fixed := fun _ => false } (sequential := true)

set_option veil.violationIsError false in
#model_check { modname := Fin 2, dir := Fin 3, proc := Fin 2 }
  { dep := fun m d => decide (m = 1 ∧ d = 0), build := 2, focus := 3,
    fixed := fun _ => false } (sequential := true)

-- m4_deleted_source_reported
#guard_msgs (drop error) in
#model_check { modname := Fin 2, dir := Fin 3, proc := Fin 2 }
  { dep := fun m d => decide (m = 1 ∧ d = 0), build := 2, focus := 4,
    fixed := fun _ => false } (sequential := true)

set_option veil.violationIsError false in
#model_check { modname := Fin 2, dir := Fin 3, proc := Fin 2 }
  { dep := fun m d => decide (m = 1 ∧ d = 0), build := 2, focus := 4,
    fixed := fun _ => false } (sequential := true)

-- m5_load_runs_chosen_object
#guard_msgs (drop error) in
#model_check { modname := Fin 2, dir := Fin 3, proc := Fin 2 }
  { dep := fun m d => decide (m = 1 ∧ d = 0), build := 2, focus := 5,
    fixed := fun _ => false } (sequential := true)

set_option veil.violationIsError false in
#model_check { modname := Fin 2, dir := Fin 3, proc := Fin 2 }
  { dep := fun m d => decide (m = 1 ∧ d = 0), build := 2, focus := 5,
    fixed := fun _ => false } (sequential := true)

/- Each expected property with its fix: no violation, up to depth 7 (as for
`focus = 0`), and every property with all the fixes. -/

#model_check { modname := Fin 2, dir := Fin 3, proc := Fin 2 }
  { dep := fun m d => decide (m = 1 ∧ d = 0), build := 2, focus := 1,
    fixed := fun f => f = fix_t_IndT.m1 } (maxDepth := 7)
-- M2's fix alone isn't enough: a module added to an earlier directory after
-- the process started is found in the stale index's later one. With `m3` too,
-- it is.
#guard_msgs (drop error) in
#model_check { modname := Fin 2, dir := Fin 3, proc := Fin 2 }
  { dep := fun m d => decide (m = 1 ∧ d = 0), build := 2, focus := 2,
    fixed := fun f => f = fix_t_IndT.m2 } (sequential := true)
#model_check { modname := Fin 2, dir := Fin 3, proc := Fin 2 }
  { dep := fun m d => decide (m = 1 ∧ d = 0), build := 2, focus := 2,
    fixed := fun f => f = fix_t_IndT.m2 ∨ f = fix_t_IndT.m3 } (maxDepth := 7)
#model_check { modname := Fin 2, dir := Fin 3, proc := Fin 2 }
  { dep := fun m d => decide (m = 1 ∧ d = 0), build := 2, focus := 3,
    fixed := fun f => f = fix_t_IndT.m3 } (maxDepth := 7)
#model_check { modname := Fin 2, dir := Fin 3, proc := Fin 2 }
  { dep := fun m d => decide (m = 1 ∧ d = 0), build := 2, focus := 4,
    fixed := fun f => f = fix_t_IndT.m4 } (maxDepth := 7)
#model_check { modname := Fin 2, dir := Fin 3, proc := Fin 2 }
  { dep := fun m d => decide (m = 1 ∧ d = 0), build := 2, focus := 5,
    fixed := fun f => f = fix_t_IndT.m5 } (maxDepth := 7)

/- `deps_loaded` and `loaded_has_code` are proved for every action, for all
instances; M1..M5 aren't invariants (the model checker shows them violated), so
this reports them as failed, without failing the build.
The table isn't pinned with `#guard_msgs` as in the other models: the SMT
solver can time out on one of M1..M5's rows (an unknown instead of a
failure), which would make the build flaky. `jank-specs.conformance.module-cache`
proves the two with `veil/prove` instead (`:prove? true`). -/
set_option veil.printCounterexamples false in
set_option veil.violationIsError false in
#check_invariants

#gen_executable

end ModuleCache
