# Reproducible measurement provenance

CodeRatchet only has a meaningful ratchet when the current measurement and the
recorded baseline mean the same thing. Provenance is therefore part of the
measurement contract, not decoration.

## Semantic identity

Every persistent measurement must have one complete semantic identity composed
of:

- a CodeRatchet metric schema version;
- the exact binding keys and their directions;
- the backend tool and exact backend version where one exists;
- compiler/runtime versions for compiler- or lowering-sensitive measurements;
- metric configuration that changes the measured population or interpretation.

The source commit is useful context, but is deliberately non-comparable because
a baseline is expected to come from an older source tree.

The current baseline writer records `binding` separately from `provenance`, and
the current comparison only checks provenance keys that happen to exist in both
maps. That is insufficient: adding a required field or changing a binding can
silently reuse an incompatible baseline.

## Required comparison rule

Construct one normalized measurement-provenance map, for example:

```julia
measurement_provenance(metric, root) = merge(
    provenance(metric, root),
    Dict(
        "schema" => metric_schema(metric),
        "binding" => collect(binding(metric)),
        "direction" => [string(direction(metric, k)) for k in binding(metric)],
    ),
)
```

The exact API may differ. The invariant is that comparable provenance uses
**exact key-set equality and exact value equality**, after removing only fields
explicitly declared informational (initially `commit`).

Consequences:

- a missing expected field fails;
- an unexpected recorded semantic field fails;
- changing a binding fails;
- changing a direction fails;
- changing a metric schema fails;
- changing a backend version fails;
- changing only the source commit does not fail.

A mismatch is not ordinary debt and must not offer a refresh artifact generated
under the wrong schema. The user must consciously upgrade/re-measure.

## Backend versions

At minimum the first implementation should close these known gaps:

- `Complexity()` records the exact `CodeComplexity` version;
- `Inference()` records the exact `JET` version;
- parser/lowering-sensitive metrics record the relevant Julia/tool identity;
- JETLS continues to bind its own version string and Julia runtime as it does
  today.

Prefer package metadata (`Base.pkgversion`) over hand-maintained version
constants where available.

## Tool pinning

Generated consumer environments and reusable workflow examples must not claim
to be reproducible while pointing at a moving `main` branch. CodeRatchet should
have one supported immutable-ref policy (release tag or exact commit) and an
explicit upgrade operation that updates the tool ref and refreshes affected
baselines in the same reviewed change.

Do not make `init` emit a ref that does not exist. Release/tag mechanics must be
established before generated configuration switches away from the current
bootstrap behavior.

## Acceptance tests

The tranche is complete only when fixtures prove all of the following:

1. missing semantic provenance key -> incompatible baseline;
2. extra stale semantic provenance key -> incompatible baseline;
3. metric schema change -> incompatible baseline;
4. binding change -> incompatible baseline;
5. direction change -> incompatible baseline;
6. backend version change -> incompatible baseline;
7. commit-only change -> comparable;
8. an incompatible baseline cannot produce a refresh artifact presented as a
   normal debt update.

This tranche changes comparability and reproducibility only. Finding-level
ratchets belong in the next stacked PR.