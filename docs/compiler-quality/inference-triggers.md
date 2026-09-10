# Inference triggers and precompile effectiveness

Cold-start timing says whether the user experience regressed. Inference
triggers say what compiler work escaped the package image and had to be paid on
the representative first use.

This should be a finding metric driven by declared workloads, not a persistent
wall-clock baseline.

## Measurement question

After the package has been precompiled and loaded in a fresh process:

> Which root MethodInstances enter inference while this representative scenario
> runs?

A new root is actionable even when runner timing noise hides its cost. Duration
and cumulative inference time are context that help rank the findings, not the
first-version gate.

## Collection

Use a fresh hermetic Julia child with the target package image already built.
The intended workflow is conceptually:

```text
prepare fresh package cache
load target package
start deep inference capture
run declared scenario
stop capture
normalize inference roots
compare finding multiset
```

SnoopCompile's deep inference tooling is specifically useful for detecting
inference that still occurs after an intended precompile workload. Keep the
collector/analyser versions in provenance.

The child must not inherit coverage, debug, startup, check-bounds or unrelated
instrumentation flags from the parent.

## Shared scenario registry

Reuse the cold-start scenario registry rather than inventing a second workload
language. A scenario should therefore be able to drive:

- paired TTFX measurement;
- runtime inference-trigger capture;
- invalidation scenario mode;
- later allocation/dispatch contracts.

For PR comparisons, workload selection follows cold-start's rule: freeze a
relative scenario file to the base revision for both base and head, with head
used only for initial bootstrap. Record source/path/content hash.

## Finding identity

The first useful fingerprint is a normalized root MethodInstance identity, for
example:

```text
owning module/package
+ generic function identity
+ normalized method signature
+ normalized specialization argument tuple
```

Do not fingerprint raw `MethodInstance` object identity, world-age ids, memory
addresses or timing. Source location is context and can be used only as a
secondary disambiguator if experiments prove the semantic signature
insufficient.

Multiplicity matters when the collector can legitimately report the same root
through independent paths.

## Context

For each finding record where available:

- inference time;
- inclusive inference time;
- whether the specialization belongs to the target package or a dependency;
- caller/root relationship;
- source method/location;
- whether it also appears in invalidation-derived reinference analysis.

Aggregate context can report:

```text
new root triggers
held root triggers
resolved root triggers
cumulative inference time
largest trigger
package/dependency ownership distribution
```

Only finding identity binds initially.

## Relationship to precompile workloads

A trigger can have several causes:

1. the representative path was never covered by precompilation;
2. covered code was invalidated after precompilation;
3. specialization was intentionally deferred because precompiling it would be
   excessive;
4. dynamic/runtime information makes advance specialization impossible.

CodeRatchet should not infer the cause from the trigger alone. Instead cross-link
with the invalidation layer below it and package-image diagnostics above it.

The useful diagnostic chain is:

```text
TTFX regression
  -> new inference trigger
  -> was the MethodInstance present in the package image?
       no  -> missing/insufficient precompile workload
       yes -> was it invalidated?
               yes -> invalidation root explains reinference
               no  -> investigate cache/world-age/load details
```

## Scope and suppression

Inference triggers are workload-dependent. Configuration must make the scenario
set explicit; changing it changes provenance. Reviewed suppressions can be used
for intentionally deferred/dynamic specializations, but they must identify a
specific normalized trigger and rationale rather than exempt a count.

## Acceptance tests

1. one old trigger resolves + unrelated new trigger appears -> FAIL;
2. same trigger with different timing only -> PASS;
3. raw MethodInstance/object identity differences do not change fingerprints;
4. signature/specialization change does change identity;
5. scenario-content change invalidates provenance;
6. new intentionally deferred trigger can be narrowly dismissed with rationale;
7. child instrumentation is hermetic;
8. target vs dependency ownership is reported;
9. inference duration remains context, not a persistent timing ratchet;
10. findings can be cross-referenced with invalidation identities where both
    describe the same specialization.

The next stacked tranche inspects what was actually serialized into the package
image so these triggers can be explained in both directions.