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
comparison has different algebra, and the type hierarchy should make accidental
mixing difficult:

```julia
abstract type Gate end
abstract type Metric <: Gate end          # existing counter protocol
abstract type FindingMetric <: Gate end   # new finding protocol

struct Finding
    subject::String
    kind::String
    discriminator::String
    message::String
    line::Int
    column::Int
end
```

`FindingMetric` is deliberately **not** a subtype of `Metric`. A `Metric` means
per-file integer `Row`s throughout the existing implementation; making findings
inherit that protocol would give them row-oriented defaults they must never use.

The primary identity is the readable canonical tuple
`(subject, kind, discriminator)`. Do not store an opaque digest as the semantic
identity. A SHA-256 may be derived from that tuple for compact CI/annotation IDs,
but the committed baseline must remain reviewable without tooling.

## Multiset, not set

A finding baseline is a **multiset** keyed by canonical identity. Two
semantically identical findings may occur twice. Omitting line numbers from
identity improves stability under harmless source movement, but multiplicity
must still detect that a second copy was introduced.

For each identity:

```text
current multiplicity - baseline multiplicity > 0  -> new finding(s)
baseline multiplicity - current multiplicity > 0  -> resolved finding(s)
min(current, baseline)                             -> held debt
```

A gate fails on new reviewed findings. Resolved findings are improvements and
must be reported, not silently discarded.

## Identity contract

An identity must be stable under unrelated line movement while changing when
the semantic problem changes. It must not contain:

- absolute checkout paths;
- raw object addresses/ids;
- compiler gensym counters unless normalized;
- line or column numbers;
- presentation-only formatting.

The fields mean:

- `subject`: repository-relative semantic subject, normally a path;
- `kind`: backend diagnostic code/class;
- `discriminator`: normalized semantic payload sufficient to distinguish two
  different defects with the same subject/kind.

Line/column and the rendered message remain presentation metadata for current
CI annotations. Identity normalization is measurement semantics and therefore
has an explicit schema version covered by the provenance tranche below this PR.

The implementation must assert that two findings with the same canonical
identity do not disagree on identity-defining normalized data. SHA collisions
are irrelevant to semantic comparison because the digest is not the key.

## JETLS migration

Current JETLS already yields structured `Diagnostic(path, line, severity, code,
message)` values. A first canonical identity can therefore be:

```text
subject       = repository-relative path
kind          = code + severity
discriminator = normalized semantic message
```

Line/column stay context. Duplicate matching diagnostics increment
multiplicity. Normalization should remove only location/path noise demonstrated
to be unstable; it must not broadly erase identifiers, types or call details
that distinguish defects.

Existing `[lsp_dismissal]` rules remain reasoned human rulings, but migration
should prefer narrow identity/pattern matches over rules capable of suppressing
an arbitrary future diagnostic class.

## JET migration

JET findings require a structured adapter around report objects. Preserve the
existing deepest-repository-frame attribution. In addition, capture a stable
enclosing owner when the virtual stack exposes one: method/function identity and
normalized signature/specTypes are preferable to a line number.

A JET identity should therefore contain at least:

```text
subject       = repository-relative attributed path
kind          = report class
discriminator = stable owner/signature + normalized semantic report payload
```

The owner matters. Without it, two textually identical `MethodErrorReport`s in
different methods of one file collapse to the same identity; fixing one while
introducing the other could then cancel through multiplicity.

Exact JET version and identity-schema version are provenance. Tests must include
reports whose rendered form contains unstable location data and prove the
normalizer removes only non-semantic movement.

## Dismissals after identity ratchets

Finding baselines already solve the adoption problem: legacy false positives
are held individually without turning the gate red. Broad dismissals are no
longer needed merely to tolerate existing debt.

That lets dismissals become stricter. A class-only JET dismissal that suppresses
every future report of that class is incompatible with the purpose of an
identity ratchet and should be rejected or migrated to a narrow semantic match.
Every dismissal still requires a reason, and an unrelated new finding must never
be hidden by an existing ruling.

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
The baseline should serialize canonical identities deterministically so a
refresh produces a small, reviewable diff.

## Renames

Do not reuse the counter metric's numeric rename heuristic. Initially, a file
rename may naturally appear as resolved old findings plus new findings at the
new path. If this proves too noisy, add a finding-specific mechanism later based
on git rename information or a deliberately path-independent semantic owner.
Do not guess from coincidentally equal diagnostics.

## Acceptance tests

The tranche is complete when tests prove:

1. old A disappears + new B appears with the same count -> FAIL;
2. duplicate multiplicity 1 -> 2 -> FAIL;
3. line-only movement of an otherwise identical finding -> PASS;
4. one finding resolves -> PASS with resolved finding reported;
5. identical report text in two distinct JET owners remains distinguishable;
6. new finding under a dismissal that exactly matches it -> does not bind;
7. an unrelated new finding cannot be hidden by that dismissal;
8. class-only/broad dismissals cannot create an open-ended hole in the gate;
9. changed identity schema/backend provenance -> incomparable baseline;
10. baseline serialization is deterministic and human-readable;
11. JET and JETLS no longer use reviewed aggregate count as their binding
    semantics.

This PR does not add new diagnostic backends. ExplicitImports/Aqua are stacked
above it so they reuse one proven finding substrate.