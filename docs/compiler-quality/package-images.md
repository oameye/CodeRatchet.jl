# Package-image diagnostics

Cold-start tells us whether startup got slower. Inference triggers tell us what
still compiled on first use. Invalidations tell us what prior compiler work was
made stale. This tranche inspects what the package image actually serialized so
those observations can be connected.

The first version is primarily diagnostic. A larger cache is not inherently
worse: useful precompilation often makes an image larger while reducing TTFX.

## Collection

Inspect the target package cache in a clean Julia process before loading the
package itself. `PkgCacheInspector` explicitly warns that inspecting a package
already loaded into the session can corrupt the session/analysis assumptions.
Use the same controlled depot/package build produced by the cold-start harness
where possible rather than precompiling a second, different environment.

Record exact Julia, PkgCacheInspector and cache-format/schema provenance.

## Structural report

At minimum report the information exposed by current PkgCacheInspector:

- package-cache file and total bytes;
- segment sizes;
- external methods;
- new specializations of external methods;
- external methods with new roots;
- external targets;
- dependency edges.

Keep raw cache bytes and aggregate counts as context initially.

## Why cache size does not bind

These two changes can both grow the package image:

```text
A. precompile the user's common first operation
B. accidentally specialize hundreds of irrelevant upstream methods
```

A can be a latency improvement; B can be compiler bloat. A simple `cache_bytes
must not rise` rule would punish the first and cannot distinguish the second.

The structural information is therefore needed before any package-image
quantity becomes a ratchet.

## Candidate future findings

After stability is demonstrated across Julia/tool versions, useful semantic
findings may include:

- newly serialized external specializations, grouped by owning package/method;
- duplicate upstream specializations that are also serialized by other known
  downstream packages;
- unexpectedly broad specialization families introduced by one method/workload;
- new external roots/targets associated with a TTFX or invalidation regression.

Do not bind these merely because PkgCacheInspector can enumerate them. First
measure fingerprint stability on real packages and decide which changes are
actually undesirable.

## Cross-layer attribution

The value of this tranche is the diagnostic join between the preceding layers:

```text
TTFX got worse
  |
  +-- new inference trigger?
  |     |
  |     +-- absent from package image
  |     |      -> precompile coverage likely missing
  |     |
  |     +-- present in package image
  |            |
  |            +-- invalidated
  |            |      -> invalidation root explains reinference
  |            |
  |            +-- not invalidated
  |                   -> investigate load/world/cache behavior
  |
  +-- no new trigger
        -> import/load/non-inference work is the likely source
```

Conversely, package-image growth can be explained by the new serialized
specializations/roots even when TTFX improves.

## Stable specialization identity

Reuse the MethodInstance/signature normalizer from inference-trigger tracking.
Do not invent a second representation of the same specialization. Where
PkgCacheInspector returns actual MethodInstances, canonicalize through the same
identity layer before comparing or cross-referencing.

Package-image metadata that depends on absolute cache paths or object identity
is context only and normalized before artifact output.

## Artifacts/reporting

Produce a machine-readable structural artifact (JSON or a stable tabular form)
in addition to a concise markdown summary. The report should highlight deltas
when base/head cache images from the same paired experiment are available, for
example:

```text
package image              6.1 MiB -> 6.4 MiB   context
external methods                  8 -> 8
external specializations        311 -> 329      +18
external methods with roots      42 -> 44       +2
external targets                905 -> 921      +16
```

Then list the identities responsible for the structural delta. Do not collapse
these into a composite score.

## Acceptance tests

1. cache inspection happens in a clean process before target-package load;
2. exact Julia/tool/schema provenance is recorded;
3. cache bytes/aggregate counts are diagnostic context only;
4. MethodInstance identities reuse the inference-trigger normalizer;
5. base/head structural deltas are deterministic on a fixed fixture;
6. absolute paths/object identities do not leak into stable identities;
7. a newly precompiled useful specialization can grow the image without
   automatically failing;
8. the report can cross-reference serialized specializations with inference and
   invalidation findings;
9. machine-readable output has an explicitly versioned schema.

This closes the initial compiler-quality stack. Hot-path allocation/dispatch
contracts and test-count/macro-expansion ratchets can be added later on top of
the same finding/counter foundations.