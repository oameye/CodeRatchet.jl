# Deterministic finding adapters

This tranche consumes the finding-ratchet substrate below it for diagnostics
that are primarily repository/package properties rather than noisy performance
observations.

Initial backends: ExplicitImports and Aqua.

## ExplicitImports

Prefer ExplicitImports' programmatic detection APIs over scraping printed test
output. The current upstream package exposes programmatic checks for:

- implicit imports;
- non-owning explicit imports;
- non-public explicit imports;
- stale explicit imports;
- non-owning qualified accesses;
- non-public qualified accesses;
- self-qualified accesses.

Map each reported problem to a CodeRatchet finding with a kind corresponding to
the upstream category and a stable subject such as module/name/owner/access
shape. Source line/column remain presentation context unless needed to
semantically distinguish two findings; multiplicity handles repeated identical
findings.

ExplicitImports documents known parser/scoping limitations, so CodeRatchet must
support reviewed suppressions with reasons rather than pretending the analyser
is infallible. Suppressions should be narrow by kind/subject/message and should
not be global count exemptions.

The adapter's provenance binds the Exact ExplicitImports version, Julia minor,
selected check set, and fingerprint schema.

## Aqua

Aqua currently covers package-level checks including method ambiguities,
undefined exports, unbound type parameters, stale dependencies, test-project
consistency, dependency compat entries, obvious type piracy, and persistent
Tasks that can block dependency precompilation.

Not every Aqua check necessarily exposes an equally convenient structured
finding API. Implement adapters only where the upstream result can be mapped to
a stable semantic identity without scraping unstable human presentation. For a
check that is naturally only pass/fail, keep it as an absolute package contract
or defer it rather than inventing fake per-file findings.

Candidate finding categories:

```text
ambiguity
undefined_export
unbound_type_parameter
stale_dependency
missing_compat
type_piracy
persistent_task
project_consistency
```

The exact set follows upstream APIs discovered during implementation.

## Avoid duplicate gates

If a repository already runs a zero-tolerance Aqua or ExplicitImports test in
its normal test suite, CodeRatchet should not encourage a duplicate expensive
check merely to own the result. The value of a finding ratchet is adoption on a
repository with reviewed legacy debt, or unified finding reporting where one
source of truth is desired.

Configuration should therefore allow individual backends/check categories to
be enabled explicitly.

## Suppression governance

Every new suppression is a correctness claim. Introduce a named rationale
registry so multiple narrow suppressions can cite one reviewed explanation
without duplicating paragraphs:

```toml
[rationale.generated-api]
text = "Names are injected by the generated public API and are not visible to the analyser."

[[finding_dismissal]]
metric = "explicit-imports"
kind = "stale_explicit_import"
subject = "..."
rationale = "generated-api"
```

A referenced rationale must exist. A rationale unused by any ruling should be
reported as stale. Adding or broadening a suppression is never an automatic
refresh operation.

## Acceptance tests

1. every enabled ExplicitImports category maps to stable finding identities;
2. same problem moving lines does not become new debt;
3. different imported/accessed name is a different finding even when category
   count is unchanged;
4. backend version/check-set changes invalidate provenance;
5. suppressions require a reason/rationale and cannot match everything;
6. stale/unused rationales are visible;
7. Aqua checks are only adapted where semantic finding identity is defensible;
8. existing zero-tolerance upstream tests can remain the sole gate without
   CodeRatchet requiring duplication.

Compiler-behavior findings such as invalidations are deliberately stacked above
this tranche because their collection environment and provenance are stricter.