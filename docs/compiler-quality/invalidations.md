# Invalidation findings

Invalidations are structural compiler debt: a newly defined or more-specific
method can make previously inferred/compiled MethodInstances stale. CodeRatchet
should track the package-owned causes that enter, not a noisy global event
count.

## Collection boundary

Capture in a pristine child Julia process with only the minimal collector loaded
before the measured action:

```julia
using SnoopCompileCore
invs = @snoop_invalidations begin
    # load package / declared trigger set
end
```

Do not load full `SnoopCompile` before capture. Analysis can happen after capture
or in a second process. The analyser must not perturb the event stream it is
supposed to explain.

The collector process uses `--startup-file=no --history-file=no` and a controlled
project/depot/load path, analogous to cold-start's hermetic child execution.

## What binds

Do not bind:

- total invalidation events;
- total invalidated MethodInstances across all dependencies;
- wall-clock time;
- raw invalidation-tree node count.

Bind canonical **root/cause findings owned by the target package**. Candidate
identity:

```text
owning/defining package or module
+ normalized inserted/redefined method signature
+ stable source definition identity
+ invalidation cause class
```

The exact SnoopCompile event representation is an adapter detail. Normalize it
at the boundary and version that normalizer explicitly.

For every bound root keep explanatory context:

- number of directly invalidated MethodInstances;
- transitive affected MethodInstances;
- maximum invalidation-tree depth;
- affected owning modules/packages;
- representative backedges/children.

Context may later become a guarded growth metric if repeated measurements prove
stable, but it is not a first-version binding.

## Why Julia version is semantic provenance

Invalidation logging and compiler behavior change between Julia releases. Julia
1.12 itself had fixes for missing invalidation-log elements, and Julia 1.13 has
continued compiler changes. Therefore provenance binds at least:

```text
Julia major.minor
SnoopCompileCore exact version
SnoopCompile exact version if used for analysis
collector schema
normalizer/fingerprint schema
load/workload hash
```

Patch version may be recorded as context and can be promoted to binding if
measurements demonstrate patch-level semantic changes. Until proven otherwise,
prefer conservative comparability.

## Package ownership

A package may trigger huge dependency cascades. The actionable finding is the
new package-owned method/cause that initiated damage, not every downstream victim.

Roots not owned by the target package stay diagnostic context unless the
configured experiment explicitly declares an extension/dependency as part of the
target ownership set.

Configuration should support such a set explicitly rather than infer ownership
from arbitrary path prefixes.

## Workload

Two modes are useful:

1. `load`: capture invalidations caused by loading the package and declared
   extension triggers;
2. `scenario`: capture invalidations caused while activating a representative
   workload or optional integration.

Scenario mode reuses the compiler-workload registry introduced by cold-start;
its content hash is provenance.

## Relationship to inference triggers

Invalidations and runtime inference answer different questions:

```text
Invalidations      -> what invalidated previously valid compiler work, and why?
InferenceTriggers  -> what compiler work did the user actually pay for afterward?
```

They should share stable MethodInstance/signature normalization where possible,
but remain separate findings. A large invalidation that is never reached by a
representative workload is structurally undesirable but may not explain TTFX;
a new inference trigger may instead be missing precompile coverage.

## Acceptance tests

1. replacing invalidation root A with root B at the same count -> FAIL;
2. a dependency-only invalidation cascade does not become target-owned debt;
3. a new target-owned root does become debt;
4. harmless line movement does not change root identity;
5. changed method signature/cause does change identity;
6. multiplicity is preserved;
7. Julia/collector/schema/workload provenance mismatch refuses comparison;
8. analyzer loading occurs after capture and cannot contribute events;
9. tree size/depth are reported as context, not first-version gates;
10. load and scenario modes are independently reproducible.

This tranche does not attempt to optimize invalidations automatically. It must
first make new compiler damage attributable and reviewable.