# Reproducible measurement provenance

CodeRatchet only has a meaningful ratchet when the current measurement and the
recorded baseline mean the same thing. Provenance is therefore part of the
measurement contract, not decoration.

## Semantic identity

Every persistent measurement has one complete semantic identity composed of:

- a CodeRatchet metric schema version;
- the exact binding keys and their directions;
- the Julia major/minor runtime version;
- the backend tool and exact backend version where one exists;
- metric configuration that changes the measured population or interpretation.

The source commit is useful context but deliberately non-comparable because a
baseline is expected to come from an older source tree.

`measurement_provenance` combines adapter provenance with `schema`, `binding`
and `direction`. Comparable provenance requires exact key-set equality and exact
value equality after removing only `commit`. Therefore a missing field, stale
field, binding change, direction change, schema change, backend version change
or semantic configuration change makes the baseline incomparable.

A provenance mismatch is not ordinary debt. Plain `refresh` refuses it; the
caller must use `--accept-change` to acknowledge and regenerate the baseline
under the new measurement semantics. Existing-but-empty baselines are still
real baselines and bind provenance; only an absent baseline is bootstrap.

Rulings-dependent measurement configuration is taken from the exact `dir` used
for the check, not recomputed from the repository root. Complexity thresholds,
full Style rule definitions (including regex text), Boxes package/load set, JET
package/load/target modules, and JETLS entry/severity/full-analysis settings all
bind because changing any of them changes the measured population or meaning.
Dismissals and coverage exemptions remain human adjudications rather than tool
identity: they are independently validated by their ruling machinery. Checks,
entry validation, ruling validation, refreshes, and refresh artifacts all use
the same selected ratchet directory; no path may silently fall back to
`ratchet_dir(root)`.

## Backend versions

The contract records the exact CodeComplexity, JET, and JETLS backend versions.
Prefer package metadata such as `Base.pkgversion` where the backend is a Julia
package; command-backed tools report their own version.

## Immutable tool identity

A reproducible baseline cannot be produced by a tool configured as `rev =
"main"`. Generated consumer environments therefore resolve CodeRatchet to an
exact 40- or 64-hex commit SHA. `CODERATCHET_REV` may provide that SHA
explicitly; otherwise a Manifest `repo-rev` or local source checkout is used. A
moving branch or abbreviated SHA is refused.

The reusable ratchet workflow additionally compares the actually installed
CodeRatchet revision with GitHub Actions' `job.workflow_sha`, the commit
containing the workflow implementation. The check deliberately ignores the
`CODERATCHET_REV` archive override, so an environment cannot claim to contain a
different tool than Pkg instantiated. This makes workflow and tool one atomic
version: pinning one while running another is an error, not a measurement.

## Acceptance

The tranche is complete when tests prove: missing and stale semantic keys fail;
schema/binding/direction/backend-version changes fail; commit-only changes stay
comparable; an existing empty baseline still binds provenance; plain refresh
refuses incompatible provenance; deliberate migration succeeds; generated
consumer configuration uses an exact commit; moving refs are rejected; and CI
refuses a workflow/tool SHA mismatch.

Finding-level identities and multiset comparison remain a separate protocol in
the next stacked PR.
