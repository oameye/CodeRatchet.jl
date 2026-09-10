# Finding-level ratchets

Integer counters are the right representation for complexity, coverage and
similar monotone quantities. Diagnostics are different: replacing one old
problem with one unrelated new problem must not pass merely because the count
stays constant.

This tranche introduces a sibling comparison protocol for stable finding
identities and migrates JET/JETLS to it.

## Model

Do not force finding semantics through the existing `Row` abstraction. The
counter ratchet deliberately assumes one repository path maps to a fixed set of
integer quantities, with rename pairing based on those numbers. Finding
comparison has different algebra.

A minimal shared hierarchy may look like:

```julia
abstract type Gate end
abstract type Metric <: Gate end          # existing counter protocol
abstract type FindingMetric <: Gate end   # new finding protocol

struct Finding
    subject::String
    kind::String
    fingerprint::String
    message::String
end
```

The exact names are not important. Keeping the comparison protocols separate
is.

## Multiset, not set

A finding baseline is a **multiset** keyed by fingerprint. Two semantically
identical findings may occur twice. Omitting line numbers from identity improves
stability under harmless source movement, but multiplicity must still detect
that a second copy was introduced.

For each fingerprint:

```text
current multiplicity - baseline multiplicity > 0  -> new finding(s)
baseline multiplicity - current multiplicity > 0  -> resolved finding(s)
min(current, baseline)                             -> held debt
```

A gate fails on new reviewed findings. Resolved findings are improvements and
must be reported, not silently discarded.

## Fingerprint contract

A fingerprint should be stable under unrelated line movement but change when
the semantic problem changes. It must not contain:

- absolute checkout paths;
- raw object addresses/ids;
- compiler gensym counters unless normalized;
- line number as the sole identity.

It should normally contain:

- repository-relative semantic subject/path;
- diagnostic kind/code/class;
- a normalized message or semantic payload;
- additional signature/type information needed to disambiguate the finding.

Location (line/column) remains presentation metadata for annotations.

Fingerprint normalization is itself measurement semantics and therefore has a
schema version covered by the provenance tranche below this PR.

## JETLS migration

Current JETLS already yields structured `Diagnostic(path, line, severity, code,
message)` values. A first fingerprint can therefore be based on:

```text
path + code + severity + normalized message
```

Line number stays context. A duplicate matching diagnostic increments
multiplicity.

Existing `[lsp_dismissal]` rules continue to filter findings before comparison.
Dismissals remain human rulings and require reasons.

## JET migration

JET findings require a normalizer around report objects. Preserve the existing
deepest-repository-frame attribution, then fingerprint at least:

```text
repository-relative attributed subject
+ report class
+ normalized semantic report text/type payload
```

Exact JET version and fingerprint schema are provenance. Tests must include
reports whose rendered form contains unstable location data and prove the
normalizer removes only non-semantic movement.

Existing `[[dismissal]]` behavior remains, but a dismissed class must never
cause unrelated reviewed findings to disappear from comparison.

## Reporting

The finding report should say both what changed and what remains:

```text
CodeRatchet jet: FAIL
  new (2)
    src/foo.jl: MethodErrorReport ...
  resolved (1)
    src/bar.jl: UndefVarErrorReport ...
  holding 7 reviewed finding(s)
```

CI annotations point to current locations for new findings. A refresh artifact
contains the current finding multiset only when provenance/rulings are valid.

## Renames

Do not reuse the counter metric's numeric rename heuristic. Initially, a file
rename may naturally appear as resolved old findings plus new findings at the
new path. If this proves too noisy, add a finding-specific rename mechanism
later based on git rename information or path-independent semantic identities.
Do not guess from coincidentally equal diagnostics.

## Acceptance tests

The tranche is complete when tests prove:

1. old A disappears + new B appears with the same count -> FAIL;
2. duplicate multiplicity 1 -> 2 -> FAIL;
3. line-only movement of an otherwise identical finding -> PASS;
4. one finding resolves -> PASS with resolved finding reported;
5. new finding under a dismissal that exactly matches it -> does not bind;
6. an unrelated new finding cannot be hidden by that dismissal;
7. changed fingerprint schema/backend provenance -> incomparable baseline;
8. JET and JETLS no longer use reviewed aggregate count as their binding
   semantics.

This PR does not add new diagnostic backends. ExplicitImports/Aqua are stacked
above it so they reuse one proven finding substrate.