#pragma once

/* Lean code that lean-sys elaborates into each session, after its imports: `LeanSys.constShapes`
 * describes how the values of a constant's type are laid out at runtime (`Shape`), from the
 * compiler's own constructor layouts, so that lean_sys.hpp can read and build them. */

namespace lean_sys
{
  inline constexpr char const *lean_source = R"lean(
namespace LeanSys
open Lean Meta

/-- A field of a constructor: where it is (`slot`: 0 erased, 1 object, 2 usize, 3 scalar,
4 unsupported), at which object or usize index, or at which byte offset among the scalars,
of which size, and the shape of its type. -/
structure FieldShape where
  name : String
  slot : Nat
  index : Nat
  size : Nat
  shape : Nat

structure CtorShape where
  name : String
  cidx : Nat
  numObjs : Nat
  numUSize : Nat
  scalarSize : Nat
  fields : Array FieldShape

/-- How the values of a type are represented at runtime. Shapes refer to each other by their
index in an array, so that recursive types have finite descriptions. `uint 0` is `USize`.
A builder is the name of a definition taking a list (of pairs, for a map) to the value. -/
inductive Shape where
  | placeholder
  | erased
  | unit
  | bool
  | nat
  | int
  | uint (bits : Nat)
  | float
  | float32
  | char
  | string
  | name
  | array (elem : Nat)
  | byteArray
  | list (elem : Nat)
  | option (elem : Nat)
  | prod (fst snd : Nat)
  | treeMap (key val : Nat) (builder : String)
  | treeSet (key : Nat) (builder : String)
  | enum (type : String) (ctors : Array String)
  | inductive (type : String) (ctors : Array CtorShape) (isStructure : Nat)
  | opaque (type : String)
  | json
  | wrap (field : String) (inner : Nat) (ctor : String)
  deriving Inhabited

/-- The shapes of a constant's parameters and of its result (of its value, when it is not a
function). `io` is 1 for an `IO` result, 2 for `BaseIO`, 3 for `CommandElabM` (run by
`runCommand`). `env` has the builders added. -/
structure ConstShapes where
  params : Array Nat
  result : Nat
  io : Nat
  shapes : Array Shape
  env : Environment
  /-- The number of parameters of its compiled code (types and proofs included). -/
  arity : Nat

structure ShapeState where
  shapes : Array Shape := #[]
  cache : Std.HashMap Expr Nat := {}

abbrev ShapeM := StateRefT ShapeState MetaM

def fieldName (n : Name) (j : Nat) : String :=
  if n.hasMacroScopes || n.isAnonymous then s!"_{j}" else n.toString (escape := false)

def ctorName (n : Name) : String :=
  match n with
  | .str _ s => s
  | _ => n.toString

/-- Adds `value` as a definition, for lean-sys to evaluate, and returns its name. -/
def addBuilder (value : Expr) : MetaM String := do
  let value ← instantiateMVars value
  let type ← inferType value
  let env ← getEnv
  let mut i := 0
  while env.contains (Name.mkSimple s!"_lean_sys_builder_{i}") do
    i := i + 1
  let n := Name.mkSimple s!"_lean_sys_builder_{i}"
  addAndCompile (.defnDecl { name := n, levelParams := [], type, value, hints := .opaque, safety := .safe })
  return n.toString

/-- Types lean-sys doesn't look into: runtime objects, and types with computed fields. -/
def opaqueTypes : List Name :=
  [``Thunk, ``Task, ``ST.Ref, ``IO.Ref, ``Lean.Environment, ``Lean.Expr, ``Lean.Level, ``Lean.Syntax,
   ``IO.Promise, ``Std.Mutex]

partial def shapeOf (t : Expr) : ShapeM Nat := do
  let t ← instantiateMVars t
  if let some i := (← get).cache[t]? then return i
  let i := (← get).shapes.size
  modify fun s => { s with shapes := s.shapes.push .placeholder, cache := s.cache.insert t i }
  let sh ← try compute t catch e => pure (.opaque s!"{← e.toMessageData.toString}")
  modify fun s => { s with shapes := s.shapes.set! i sh }
  return i
where
  compute (t : Expr) : ShapeM Shape := do
    if ← isProp t then return .erased
    let t ← whnf t
    if t.isSort then return .erased
    if t.isForall then
      let typeFormer ← forallTelescopeReducing t fun _ b => return (← whnf b).isSort
      return if typeFormer then .erased else .opaque "function"
    let .const c _ := t.getAppFn | return .opaque (toString (← ppExpr t))
    let args := t.getAppArgs
    if opaqueTypes.contains c then return .opaque c.toString
    match c with
    | ``Nat => return .nat
    | ``Int => return .int
    | ``Bool | ``Decidable => return .bool
    | ``String => return .string
    | ``Char => return .char
    | ``Float => return .float
    | ``Float32 => return .float32
    | ``UInt8 => return .uint 8
    | ``UInt16 => return .uint 16
    | ``UInt32 => return .uint 32
    | ``UInt64 => return .uint 64
    | ``USize => return .uint 0
    | ``PUnit | ``Unit => return .unit
    | ``Lean.Name => return .name
    | ``Lean.Json => return .json
    | ``ByteArray => return .byteArray
    | ``Array => return .array (← shapeOf args[0]!)
    | ``List => return .list (← shapeOf args[0]!)
    | ``Option => return .option (← shapeOf args[0]!)
    | ``Prod => return .prod (← shapeOf args[0]!) (← shapeOf args[1]!)
    | ``Std.ExtTreeMap => treeMap ``Std.ExtTreeMap.ofList args
    | ``Std.TreeMap => treeMap ``Std.TreeMap.ofList args
    | ``Std.ExtTreeSet => treeSet ``Std.ExtTreeSet.ofList args
    | ``Std.TreeSet => treeSet ``Std.TreeSet.ofList args
    | ``Std.DTreeMap.Internal.Impl =>
      return .treeMap (← shapeOf args[0]!) (← shapeOf (← constantValueType args[1]!)) ""
    | _ => inductiveShape c args
  treeMap (ofList : Name) (args : Array Expr) : ShapeM Shape := do
    let (k, v, cmp) := (args[0]!, args[1]!, args[2]!)
    let builder ← withLocalDeclD `l (← mkAppM ``List #[← mkAppM ``Prod #[k, v]]) fun l => do
      addBuilder (← mkLambdaFVars #[l] (← mkAppOptM ofList #[k, v, l, cmp]))
    return .treeMap (← shapeOf k) (← shapeOf v) builder
  treeSet (ofList : Name) (args : Array Expr) : ShapeM Shape := do
    let (k, cmp) := (args[0]!, args[1]!)
    let builder ← withLocalDeclD `l (← mkAppM ``List #[k]) fun l => do
      addBuilder (← mkLambdaFVars #[l] (← mkAppOptM ofList #[k, l, cmp]))
    return .treeSet (← shapeOf k) builder
  constantValueType (b : Expr) : ShapeM Expr := do
    match b with
    | .lam _ _ body _ =>
      if body.hasLooseBVars then throwError "a map whose values' type depends on the key" else pure body
    | _ => throwError "a map whose values' type depends on the key"
  inductiveShape (c : Name) (args : Array Expr) : ShapeM Shape := do
    let env ← getEnv
    let some (.inductInfo info) := env.find? c | return .opaque c.toString
    let ctors ← info.ctors.toArray.mapM fun n => do
      let some (.ctorInfo ci) := env.find? n | throwError "no constructor {n}"
      pure ci
    if let some ts ← Compiler.LCNF.hasTrivialStructure? c then
      let some ci := ctors.find? (·.name == ts.ctorName) | throwError "no constructor {ts.ctorName}"
      let ctype ← instantiateForall ci.type (args.extract 0 ci.numParams)
      return ← forallTelescopeReducing ctype fun xs _ => do
        let field := xs[ts.fieldIdx]!
        -- A type with one constructor and one field is that field at runtime. An inductive type
        -- keeps its constructor and field (a Veil label type with one action); a structure
        -- defined in the session keeps its field's name (a Veil state with one field); a
        -- library's structure (`Fin`) is its field.
        let name := fieldName (← field.fvarId!.getUserName) ts.fieldIdx
        if !isStructure env c then
          return .wrap name (← shapeOf (← field.fvarId!.getType)) (ctorName ci.name)
        if (env.getModuleIdxFor? c).isNone then
          return .wrap name (← shapeOf (← field.fvarId!.getType)) ""
        compute (← field.fvarId!.getType)
    if ctors.all (·.numFields == 0) then
      if ctors.size == 1 then return .unit
      return .enum c.toString (ctors.map (ctorName ·.name))
    let mut shapes := #[]
    for ci in ctors do
      let layout ← Compiler.LCNF.getCtorLayout ci.name
      let ctype ← instantiateForall ci.type (args.extract 0 ci.numParams)
      let fields ← forallTelescopeReducing ctype fun xs _ => xs.mapIdxM fun j x => do
        let decl ← x.fvarId!.getDecl
        let (slot, index, size) := match layout.fieldInfo[j]? with
          | some (.object i _) => (1, i, 0)
          | some (.usize i) => (2, i, 0)
          | some (.scalar sz off _) => (3, off, sz)
          | some .erased | some .void => (0, 0, 0)
          | _ => (4, 0, 0)
        let shape ← if slot == 0 || slot == 4 then pure 0 else shapeOf decl.type
        pure ({ name := fieldName decl.userName j, slot, index, size, shape } : FieldShape)
      shapes := shapes.push ({ name := ctorName ci.name, cidx := layout.ctorInfo.cidx, numObjs := layout.ctorInfo.size,
                               numUSize := layout.ctorInfo.usize, scalarSize := layout.ctorInfo.ssize, fields } : CtorShape)
    return .inductive c.toString shapes (if isStructure env c then 1 else 0)

def runMeta (env : Environment) (x : MetaM α) : IO (α × Environment) := do
  let ctx : Core.Context := { fileName := "<lean-sys>", fileMap := default, maxHeartbeats := 0 }
  let (a, s) ← (x.run' {} {}).toIO ctx { env }
  return (a, s.env)

def ioKind (t : Expr) : Nat :=
  if t.isAppOfArity ``IO 1 || t.isAppOfArity ``EIO 2 then 1
  else if t.isAppOfArity ``BaseIO 1 then 2
  else if t.isAppOfArity ``Lean.Elab.Command.CommandElabM 1 then 3
  else 0

/-- Runs a command elaborator's action in command state `st` (a session's), as a command would
run. -/
def runCommand (st : Elab.Command.State) (x : Elab.Command.CommandElabM α) :
    IO (α × Elab.Command.State) := do
  let ctx : Elab.Command.Context :=
    { fileName := "<lean-sys>", fileMap := default, snap? := none, cancelTk? := none }
  match ← ((x ctx).run st).toBaseIO with
  | .ok r => pure r
  | .error e => throw (IO.userError (← e.toMessageData.toString))

def constShapes (env : Environment) (c : Name) : IO ConstShapes := do
  let ((params, result, io, st), env) ← runMeta env do
    let some ci := (← getEnv).find? c | throwError "unknown constant {c}"
    let ((params, result, io), st) ← (forallTelescope ci.type fun xs body => do
      let params ← xs.mapM fun x => do shapeOf (← x.fvarId!.getType)
      let io := ioKind body
      let result ← shapeOf (if io == 0 then body else body.appArg!)
      return (params, result, io) : ShapeM _).run {}
    return (params, result, io, st)
  let arity := match IR.findEnvDecl env c with
    | some d => d.params.size
    | none => params.size
  return { params, result, io, shapes := st.shapes, env, arity }

/-- The axioms constant `n` depends on (`sorryAx` when its proof has a `sorry`, an axiom of its
own when it trusts compiled code, as `native_decide` does). -/
def axiomsOf (n : Name) : Elab.Command.CommandElabM (Array Name) :=
  Elab.Command.liftCoreM (Lean.collectAxioms n)

/-- C code for constant `n` and the local definitions it uses, with the local initializers, as
Lean's compiler emits it; the C name of `n`; and the name of the emitted module initializer. -/
def emitC (n : Name) : Elab.Command.CommandElabM (String × String × String) :=
  Elab.Command.liftCoreM do
    let env ← getEnv
    let initializers := (← Compiler.LCNF.getLocalImpureDecls).filter fun d =>
      !isMarkedMeta env d && (isIOUnitInitFn env d || hasInitAttr env d)
    let (used, _) ← Compiler.LCNF.collectUsedDecls (#[n] ++ initializers)
    let code ← Compiler.LCNF.emitCForDecls env.mainModule (used.map (·.name))
    return (code, n.mangle, mkModuleInitializationFunctionName env.mainModule)

end LeanSys
)lean";
}
