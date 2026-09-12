# Finding identities and multiset ratchets

CodeRatchet currently prevents aggregate quality debt from increasing. For
finding-producing metrics such as JET and JETLS, an aggregate count is not
strong enough: one diagnostic can disappear while a different diagnostic
appears and the count stays unchanged.

This tranche adds a second binding layer beneath the existing per-file numbers.

## Contract

A finding-aware metric records, for every file, both its existing numeric row
and a **multiset** of reviewed finding identities. The multiset is binding.

For one file with baseline multiset `B` and current multiset `C`, the gate
permits removals but rejects every positive multiplicity in `C - B`. Therefore
an old finding may disappear, but a different finding cannot silently replace
it merely because the reviewed count stayed constant or even fell.

Duplicates remain duplicates. If an identical finding occurs once in the
baseline and twice now, that is a regression from multiplicity one to two.

The existing reviewed count remains binding and must equal the size of the
finding multiset. This gives the baseline a simple audit invariant and preserves
existing scorecards and debt summaries.

## Location independence

Source location is presentation, not identity. Moving otherwise unchanged code
must not create a new finding.

The file path is already the outer baseline key, so it is not duplicated inside
the finding identity. Line and column numbers never bind.

JETLS identity is the parsed severity, diagnostic code, and message:

```text
[<severity>:<code>] <message>
```

JET identity combines a location-free enclosing MethodInstance owner with JET's
location-free report rendering (report class, semantic message, and expression
signature). This prevents identical-looking reports in two different methods
from cancelling by multiplicity while still excluding file paths and line
numbers from the identity.

JET's virtual stack trace is used to determine ownership and attribution, but
source locations from that stack never bind. Backend versions already bind in
measurement provenance. A JET/JETLS release that changes diagnostic wording or
report semantics therefore requires an explicit provenance migration rather
than silently changing finding identity.

Dismissals remain possible, but they must be semantically narrow. Every JET
`[[dismissal]]` and JETLS `[[lsp_dismissal]]` requires a non-empty message
`pattern` and a reason. JET `class`, and JETLS `code`/`severity`, are optional
narrowing fields; they cannot stand alone. This prevents a category-level rule
from becoming an open-ended hole for unrelated future findings.

## Baseline format

Finding-aware file rows add a generated `findings` array. The array is sorted
for deterministic diffs and retains repeated strings for multiplicity.

```toml
[files."src/example.jl"]
raw = 3
reviewed = 2
findings = [
  "[info:lowering/unused-argument] Unused argument `x`",
  "[warn:inference/type-error/non-bool-cond] non-boolean `Missing` found in boolean context",
]
```

Metrics that do not opt into finding identity keep their current baseline
shape.

## Comparison and migration

Finding-aware adapters declare which numeric binding key the multiset explains;
for JET and JETLS this is `reviewed`. Every current and comparable baseline row
must satisfy

```text
reviewed == length(findings)
```

Rename pairing includes the finding multiset in addition to all recorded
numbers. A new file may not enter with reviewed findings. A plain refresh may
remove resolved findings but may not record a new finding; `--accept-change`
remains the explicit escape hatch for deliberate baseline changes.

JET and JETLS increment their metric schema when this protocol lands, so old
count-only baselines cannot be mistaken for finding-aware baselines.

## Acceptance

The tranche is complete when tests prove that:

- replacing one finding by another at equal reviewed count fails;
- a new finding still fails when more old findings disappeared and the reviewed
  count decreased overall;
- increasing the multiplicity of an existing identity fails;
- removing findings passes;
- moving an unchanged finding to a different line in the same file passes;
- an exact file rename preserves history when numbers and findings match;
- a new file with reviewed findings fails entry validation;
- plain refresh refuses a finding regression;
- JETLS identity excludes line/column but includes severity, code, and message;
- JET identity excludes source locations, includes the enclosing method owner,
  and includes report class plus rendered semantic report content;
- identical JET report payloads in distinct methods remain distinct findings;
- class-only JET dismissals are rejected;
- code- or severity-only JETLS dismissals are rejected;
- invalid dismissal configuration is rejected even when the measured backend
  reports no findings;
- count-only JET/JETLS baselines are provenance-incompatible and require an
  explicit migration.
