# CodeRatchet.jl

A per-file **ratchet** for Julia code-quality metrics.

The ratchet is the whole idea: a number only has to stop getting worse. That is
what makes a gate adoptable on a codebase where the absolute bar is out of
reach today, which an absolute gate never is. "JET reports zero" cannot be
switched on for a package with 200 reports. "No file gains a report" can be
switched on this afternoon.

Six metrics today, one comparison rule:

| Metric | Binds on | Context it also records | Cost |
| --- | --- | --- | --- |
| `Complexity()` | the **maximum** over a file's definitions, and the **count above threshold** | the sums | ~1 s |
| `Coverage()` | a file's **unexempted miss count** | relevant lines, exempted lines | ~1 s |
| `Style()` | one count per configured house rule | nothing; every rule binds | ~1 s |
| `Docstrings()` | a file's **undocumented public name** count | how many public names it defines | ~1 s |
| `Boxes()` | a file's **`Core.Box`** count | nothing; the count is the whole finding | seconds |
| `Lsp()` | a file's **reviewed** JETLS diagnostic count | the raw count | ~30 s |
| `Inference()` | a file's **reviewed** JET report count | the raw count | minutes |

Ordered by cost, and a repository should run them in that order: a gate that
takes a second and catches the common mistake should fail before one that takes
minutes.

## Why those numbers and not the obvious ones

Each choice is the difference between a gate people keep and a gate people
switch off. **All of them are Daniel Celis Garza's**, worked out in
PortfolioOptimisers.jl; see [Prior art](#prior-art).

**Complexity binds on the maximum, not the sum.** A new helper of complexity 2
in a file whose maximum is 9 moves nothing, so ordinary work is quiet. The sum
moves by 2 and would turn the gate red, and that failure is noise. A noisy gate
gets switched off, and then it protects nothing. The sums are still recorded,
because the maximum is blind to sprawl and the ranking job needs them.

**The maximum alone leaves a hole, and the count closes it.** A file sitting at
18 absorbs a brand new definition at 17 without moving: the maximum is
unchanged, the gate reports PASS, and that file now has two bad definitions
where it had one. Counting how many stand above the threshold makes the second
one visible while staying quiet about the helper at 2. This does not make the
threshold a pass rule, because the count is ratcheted like every other number:
a file with five definitions above the threshold stays green at five and goes
red at six. The threshold decides what counts as bad; the ratchet still decides
what fails.

**Coverage binds on misses, not percentage.** The percentage rises when an
uncovered line is deleted and when a covered one is added, so a file can
improve its percentage while gaining misses. The miss count is the number that
goes to zero, and it moves the right way on its own: adding a covered function
raises `lines` and leaves `misses` alone.

**JET binds on the reviewed count, not the raw one.** A dismissal covers a
*class* of report, so the fifteenth instance of an already-dismissed class must
stay green. Binding on the raw count would turn every new instance of a known
non-defect red.

**Style binds a preference, which is what a ratchet is for.** A house rule is
not a defect, so an absolute gate on one is unadoptable the day it is written:
the rules most worth holding are the ones the codebase already breaks. Adding a
rule to such a repository turns every offending file red at once, because a
number absent from the baseline reads as zero, and the first
`refresh --accept-change` writes the debt down in a diff a reviewer can size.
Named syntax-tree rules come first and a regex escape hatch second: a regex
that has to know Julia syntax is a regex that is wrong on the case you have not
thought of yet.

**Boxes binds a count, and the Julia version is part of provenance.** Lowering
decides what boxes, and lowering changes between releases: 1.12 stopped boxing a
capture reassigned *before* the closure is built, which is the textbook example.
A baseline from another minor version is not comparable, so the version binds
and a mismatch fails with a reason rather than handing back a phantom
improvement.

**JETLS is not a second JET.** JET analyses inference; JETLS analyses lowering,
and finds undefined globals, unused imports and arguments, and dead branches.
The two overlap almost nowhere. `Lsp()` also defaults `skip_full_analysis` to
false, against the habit the flag invites: skipping the full analysis leaves
JETLS without the module a file belongs to, so its imports read as unused and
its macros read as undefined. Measured on a nine-file package, the flag turned
seven real diagnostics into fourteen mostly false ones.

**Docstring coverage binds on undocumented names, not on a ratio.** A ratio
rises when a public name is deleted, and a documented count rises when a
private helper is exported. The undocumented count has a reachable zero and
moves the right way on its own. Public means *declared* public: an `export`, a
`public`, or a `@public` macro. A name nothing declares is internal, and the
rule most repositories actually hold is about the interface.

**Thresholds are not the pass rule.** The ratchet stops decay; driving
improvement is a separate, paced job. A file far above every threshold stays
green while its numbers hold steady, and shows up under `candidates` instead.

**Parseability is checked separately.** CodeComplexity parses with
`ignore_errors = true`, so a file with a syntax error is measured as though it
were correct and reports an artificially low number. A gate that stops
measuring without failing is worse than no gate.

## Setting it up in a repository

```sh
julia -e 'using CodeRatchet; exit(CodeRatchet.main())' init
julia --project=code_ratchet -e 'using Pkg; Pkg.instantiate()'
julia --project=code_ratchet -e 'using CodeRatchet; exit(CodeRatchet.main())' all refresh
```

`init` writes both configuration files from what the repository already says:
the package name and UUID from its `Project.toml`, the measured scope from the
directories that exist, and an `[[unmeasured_path]]` for every other directory
git tracks a `.jl` file in. That last part is why the first `all check` is
green rather than a list of orphaned files, which is the moment most people
decide a tool is not worth it. It never overwrites an existing `rulings.toml`
without `--force`.

Only the three metrics needing no extra setup are switched on. `coverage`,
`boxes`, `lsp` and `jet` are written in commented out, because switching on a
gate a repository cannot yet run makes its first check fail for a reason that
has nothing to do with its code.

**CodeRatchet needs Julia 1.12, and your package does not.** The ratchet
environment is its own, so a package supporting 1.10 can still be gated by a
job running 1.12.

### In CI

```yaml
jobs:
  ratchet:
    uses: oameye/CodeRatchet.jl/.github/workflows/ratchet.yml@main
    with:
      julia-version: '1.12'
      coverage: true                   # only if you run the coverage metric
      install-jetls: true              # only if you run the lsp metric
      jetls-rev: '6893fcef26...'       # pin it; `release` moves under you
      metrics: 'complexity style docs' # optional: narrow, never widen
```

Calling the workflow rather than copying it means the gate's CI behaviour has
one definition. Forty copies drift; one call does not.

`coverage: true` runs the tests with coverage and builds the `lcov.info` the
coverage metric reads, since that metric measures a tracefile rather than the
source and has nothing to read without one.

`metrics` narrows `[metrics].run` for that job and can never add to it.
Narrowing is a legitimate thing to want: a repository whose JET is already
gated absolutely by another workflow should not pay for JET twice. Widening
would be a second source of truth, so it is refused.

### Cold-start regression tracking

Cold-start is a separate paired experiment rather than a persistent metric.
It compares exact base and head revisions on the same runner, with independent
target-package cache builds and fresh Julia processes for each scenario sample.
Only package precompile time and total time-to-first-execution gate; import,
compilation/recompilation, warm latency and cache bytes remain diagnostic context.

Put representative zero-argument workloads in
`benchmark/precompile/scenarios.jl` as an ordered named tuple named
`PRECOMPILE_BENCHMARKS`. For an ordinary PR, CodeRatchet deliberately uses the
**base revision's** scenario file for both revisions, so the candidate cannot
silently redefine the benchmark that judges it. The head scenario file is used
only to bootstrap a repository whose base has no scenario registry yet. The
result artifact records `scenario_source`, `scenario_path` and `scenario_hash`.

```toml
[coldstart]
scenarios = "benchmark/precompile/scenarios.jl"
builds = 2
samples = 5
absolute_ms = 50
relative = 0.05
precompile_tasks = 1
```

The reusable `coldstart.yml` workflow performs the paired comparison. Timing is
intentionally not written into the normal CodeRatchet baseline: runner noise is
handled by same-run base/head comparison and explicit materiality floors instead.

### By hand



Add a `code_ratchet/` directory with two files.

`code_ratchet/Project.toml`:

```toml
[deps]
CodeRatchet = "0e86a969-c127-44ad-8bee-7851ffae31d4"
YourPackage = "..."                 # only the JET metric needs this
JET = "c3a54625-cd67-489e-a8e7-0a5a0ff4e31b"

[sources]
CodeRatchet = {url = "https://github.com/oameye/CodeRatchet.jl", rev = "main"}
YourPackage = {path = ".."}
```

`code_ratchet/rulings.toml` is the hand-written half. Nothing in it is measured,
and no verb in this package ever rewrites it. That split is the point: no human
paragraph shares a file that a refresh overwrites.

```toml
[scope]
measure = ["src/", "ext/"]

[thresholds]
cyclomatic = 10
cognitive = 15
argcount = 10

[[unmeasured_path]]
path = "test/"
reason = "Test code. Its complexity is not the package's."

[[exemption]]                        # coverage only
path = "src/precompile.jl"
definition = "warmup"                # or "<toplevel>" for a const or include
misses = 4
reason = "The workload body never runs under the test process."

[[dismissal]]                        # JET only
class = "MethodErrorReport"
pattern = "Symbol"
reason = "Symbolic dispatch the analyser cannot follow."

[jet]
package = "YourPackage"
target_modules = ["YourPackage"]
load = []                            # extension triggers, if any

[style]                              # style only
rules = ["union_nothing", "underscore_name", "implicit_kwarg"]

[[style_pattern]]                    # style only, for a rule no built-in covers
name = "debug_print"
pattern = "^\\s*println\\("
reason = "Debug output left in library code."

[boxes]                              # boxes only
package = "YourPackage"
load = []

[lsp]                                # lsp only
entry = ["src/YourPackage.jl"]       # what `jetls check` is pointed at

[[lsp_dismissal]]                    # lsp only
code = "lowering/unsorted-import-names"
reason = "Exports are grouped by concept here, not alphabetically."
```

The built-in style rules:

| Rule | Counts |
| --- | --- |
| `union_nothing` | `Union{Nothing,T}` in any position, however either name is qualified |
| `underscore_name` | a definition named with a leading underscore, and the file itself when its name carries one |
| `implicit_kwarg` | a keyword passed at a call site with no `;`: `f(a = 1)` rather than `f(; a = 1)` |

`implicit_kwarg` exempts definition signatures, and the exemption is
load-bearing rather than lenient: `f(x, a = 1)` in a signature declares an
*optional positional* argument, which the parser also represents as `:kw`.

`Lsp()` needs the [`jetls`](https://github.com/aviatesk/JETLS.jl) binary on
`PATH`, not a Julia dependency:

```sh
julia -e 'using Pkg; Pkg.Apps.add(; url="https://github.com/aviatesk/JETLS.jl", rev="release")'
```

Every tracked `.jl` file must be either inside `[scope].measure` or named by an
`[[unmeasured_path]]`. A file that is neither turns the gate red. The assertion
is the point: a new top-level directory cannot fall through unmeasured and
silent.

Then take the first baselines with `all refresh`, or one metric at a time.

## Using it

```sh
coderatchet all check                     # every configured gate, cheapest first
coderatchet all refresh                   # every baseline
coderatchet all scorecard                 # where the recorded debt actually is

coderatchet complexity check              # exit 1 if any binding number rose
coderatchet complexity refresh            # refuses if a number rose
coderatchet complexity refresh --accept-change # record a worse number, deliberately
coderatchet complexity candidates         # rank work; never gates
coderatchet complexity triage --issues open.tsv   # plan the issues to open
coderatchet coverage terminal             # files still short of zero misses
coderatchet boxes methods                 # name every boxed capture, and its variable
coderatchet lsp report                    # every undismissed JETLS diagnostic
coderatchet docs undocumented             # every public name owing a docstring
```

`terminal`, `candidates`, `methods` and `report` say what to *fix*; the ratchet
says only what *regressed*. A count is not actionable on its own, so each of
them names the thing rather than counting it.

where `coderatchet` is
`julia --project=code_ratchet -e 'using CodeRatchet; exit(CodeRatchet.main())'`.
The JET metric additionally needs `using JET` in that call, because it lives in
a package extension.

`[metrics].run` in `rulings.toml` names which gates `all` runs. It is the one
place the set is written down: a list of commands in a Makefile is a second
place, and the two drift.

`scorecard` reads the baselines rather than measuring, so it costs nothing and
answers the question the gate never does. `check` says what regressed; the
scorecard says where the debt is, ranked by how many metrics flag a file rather
than by the numbers, because a cyclomatic 11 and a JET report are not on one
scale and adding them would invent a total that means nothing.

```
3 file(s) carrying debt, worst first, across complexity, style, docs, boxes, lsp, jet:
  src/gksl_coordinates.jl   complexity: cyc_over=2 cog_over=2  |  lsp: reviewed=1
  src/engine.jl             complexity: cog_over=1
  src/periodic_operator.jl  lsp: reviewed=1
  (6 file(s) at zero, not listed)
```

A maximum never appears there. Every non-empty file has a cyclomatic maximum of
at least one, so a nonzero `cyc` is not evidence of anything, and listing it
would bury the numbers that are. That is `debt(metric, key)`, and it is a
separate question from `binding`: a maximum both binds and is not debt.

Environment: `CODERATCHET_ROOT` (repository root, default `pwd()`),
`CODERATCHET_DIR` (default `<root>/code_ratchet`), `COVERAGE_LCOV`.

## PASS is not clean

A ratchet's `PASS` means *did not rise*, so the verdict always carries the debt
behind it:

```
CodeRatchet complexity: PASS, holding cog_over=3, cyc_over=5
CodeRatchet style: PASS, clean
CodeRatchet coverage: PASS, holding misses=267
```

Writing this package I misread my own output three times in one sitting:
`boxes: PASS` while the baseline held three boxes, `jet: PASS` while twelve
reports stood. The numbers were in hand each time and the gate declined to
mention them. A gate that can be mistaken for a clean bill of health is worse
than a loud one.

Totals skip a maximum, for the same reason the scorecard does: every non-empty
file has a cyclomatic maximum, so a total over maxima means nothing. See
[`debt`](#using-it).

## What turns the gate red

A rise in a binding number is the obvious one. These are the rest, and each
closes a way the gate could otherwise be quietly wrong.

- **A file in scope with no baseline row.** Without this a new file passes at
  any number at all until some later refresh bakes it in silently. Demanding
  the row puts the number in the diff of the change that introduced it.
- **A baseline row naming no file.** The same failure from the other side.
- **A tracked `.jl` file that is neither in scope nor declared unmeasured.** A
  new top-level directory cannot fall through unmeasured and silent.
- **A file that does not parse.**
- **An exemption whose count does not match the truth**, in either direction. A
  claim above the truth is stale. A claim below it is a leak the file total
  cannot see, because a line covered elsewhere in the file pays for a new
  uncovered line inside the exempted definition and the file's miss count stays
  flat.
- **Provenance that moved under the baseline.** The numbers came from a
  different tool, so comparing them at all would be meaningless.

The first run, with no baseline, is the bootstrap case and reports none of
these. `refresh` and it becomes the tree the ratchet holds.

## In CI

A failing check does three things beyond exiting 1.

- One `::error file=…::` annotation per offending file, so the failure lands on
  the diff rather than only in a log.
- A markdown rise table appended to `$GITHUB_STEP_SUMMARY`.
- A **refresh artifact**: the baseline as `refresh --accept-change` would have
  written it, under `<ratchet dir>/_refresh/`. Upload it from the failing run,
  and a contributor fixes a red gate by downloading the file and committing it
  at its recorded path. No Julia, no local environment.

A provenance failure suppresses the artifact, because a baseline built from the
wrong tool is the wrong file to commit.

## Driving improvement

The ratchet stops decay and says nothing about getting better. `triage` is the
other half: it ranks what stands above threshold, drops what the tracker
already names, and writes a plan of issues to open under
`<ratchet dir>/_triage/` as `NNN-title` and `NNN-body` pairs.

It opens nothing and reads no issue body. Feed it `gh issue list` output as
`number<TAB>state<TAB>title` and let `gh` create what the plan names, so every
decision lives in one place a person can run and read.

Three rules decide the plan. One issue per file rather than per definition,
because a file with four breaches is one piece of work. A file the tracker
already names is suppressed. And **the cap is on the open-issue count, not on
this run**: a per-run cap is blind to throughput, so an unworked backlog would
grow at a fixed rate, while capping the queue makes it pace itself to what
actually closes.

## Direction

A binding number moves one way by default: **down**. Nearly every quality
number has a complement that is also a number, and the one worth binding is the
one with a reachable zero. Misses rather than percentage, undocumented rather
than documented.

`direction(metric, key)` can return `:up` for a quantity with no complement to
count. The clearest case is how many assertions a test file makes: there is no
such thing as a test not written, so the only gate available is that the number
must not fall. Deleting tests to turn CI green is a real failure mode, and it
is invisible to every `:down` number here. No shipped metric binds `:up` yet;
the trait is what a metric that needs it would use.

The remedy follows the direction, so a `:up` metric is told to raise its number
rather than lower it, and a violation reads "rose" or "fell" off its own two
values. The refresh flag is `--accept-change` for the same reason, since a
number binding `:up` is a violation when it falls.

## Renames

A file that vanishes and one that appears carrying an identical **full** number
set are paired, and the baseline carries over. Pairing uses every recorded
number rather than the binding subset, because two unrelated files often share
a worst definition and pairing those would carry the wrong history forward. An
ambiguous pairing is refused rather than guessed.

## Adding a metric

Implement five methods. Nothing else in the package learns what your numbers
mean.

```julia
struct MyMetric <: CodeRatchet.Metric end

CodeRatchet.metric_name(::MyMetric) = "mymetric"        # baseline filename stem
CodeRatchet.binding(::MyMetric) = ("thing",)            # what turns the gate red
CodeRatchet.row_numbers(::MyMetric) = ("thing", "context")
CodeRatchet.measure(::MyMetric, root) = Dict("src/a.jl" => CodeRatchet.Row(...))
CodeRatchet.provenance(::MyMetric, root) = Dict("metric" => "mymetric")
```

Override `strict_new(::MyMetric) = true` when a file absent from the baseline
must enter clean. `Coverage` does; `Complexity` does not, because it has no
meaningful zero.

`provenance` is written into the baseline and asserted on read, so a baseline
is never compared against a run that measured a different thing. The JET metric
records its load set there, because loading a dependency's extension triggers
changes which methods exist and therefore the number.

## Prior art

This package is a reimplementation of the ratchet in the `code_health/`
directory of [PortfolioOptimisers.jl](https://github.com/dcelisgarza/PortfolioOptimisers.jl)
by Daniel Celis Garza (MIT), described in [this Discourse
post](https://discourse.julialang.org/t/idiomatic-julia-code-in-ai-generated-code/139183/4).

**Every binding decision documented above is his**, and several docstrings in
this package paraphrase his rationale comments closely enough to be derived
text rather than independent authorship. A second pass, after reading his
implementation rather than only its rationale, took the set-equality rule, the
per-definition coverage attribution, the two-directional exemption check, the
`git ls-files` file list, the CI annotations and refresh artifact, the ordered
remedy routes, and the open-queue cap on the scheduled job. `LICENSE` itemises
all of it.

What differs here is packaging, not insight. His version is three standalone
scripts per repository, each of which has to be included into a module of its
own because they all name their entry point `measure`. This is one deep
`ratchet` that knows nothing about the numbers, plus a `Metric` adapter
interface, so it installs once and serves many repositories, and JET sits
behind a weak dependency. The `Metric` interface, `strict_new`, provenance
asserted on read, exemption netting, `stale_exemptions`, the CLI and the tests
are this package's own.

Not carried over from his setup: the scheduled job that files ranked
code-health issues with a capped open queue, the macro-expansion metric, and
the ADR-linked approval structure for rulings.

## Status

Used by FloquetExpansions.jl. Not registered. `Inference()` needs Julia 1.12
and JET 0.12.
