import Lake
open Lake DSL

package leanSysExample

@[default_target]
lean_lib LeanSysExample where
  defaultFacets := #[LeanLib.sharedFacet]
