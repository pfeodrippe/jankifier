import Lake
open Lake DSL

require veil from git "https://github.com/verse-lab/veil.git" @ "v4.35.0"

package jankSpecs

@[default_target]
lean_lib JankSpecs where
  globs := #[.submodules `JankSpecs]
