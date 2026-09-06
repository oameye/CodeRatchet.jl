# CodeRatchet.jl

A per-file **ratchet** for Julia code-quality metrics.

The ratchet is the whole idea: a number only has to stop getting worse. That is
what makes a gate adoptable on a codebase where the absolute bar is out of
reach today, which an absolute gate never is. "JET reports zero" cannot be
switched on for a package with 200 reports. "No file gains a report" can be
switched on this afternoon.

Three metrics today, one comparison rule:

| Metric | Binds on | Context it also records | Cost |
| --- | --- | --- | --- |
| `Complexity()` | the **maximum** over a file's definitions, per metric | the sums | ~1 s |
| `Coverage()` | a file's **unexempted miss count** | relevant lines, exempted lines | ~1 s |
| `Inference()` | a file's **reviewed** JET report count | the raw count | minutes |

## Why those numbers and not the obvious ones

Each choice is the difference between a gate people keep and a gate people
switch off. **All of them are Daniel Celis Garza's**, worked out in
PortfolioOptimisers.jl; see [Prior art](#prior-art).

**Complexity binds on the maximum, not the sum.** A new helper of complexity 2
in a file whose maximum is 9 moves nothing, so ordinary work is quiet. The sum
moves by 2 and would turn the gate red, and that failure is noise. A noisy gate
gets switched off, and then it protects nothing. The sums are still recorded,
because the maximum is blind to sprawl and the ranking job needs them.

**Coverage binds on misses, not percentage.** The percentage rises when an
uncovered line is deleted and when a covered one is added, so a file can
improve its percentage while gaining misses. The miss count is the number that
goes to zero, and it moves the right way on its own: adding a covered function
raises `lines` and leaves `misses` alone.

**JET binds on the reviewed count, not the raw one.** A dismissal covers a
*class* of report, so the fifteenth instance of an already-dismissed class must
stay green. Binding on the raw count would turn every new instance of a known
non-defect red.

**Thresholds are not the pass rule.** The ratchet stops decay; driving
improvement is a separate, paced job. A file far above every threshold stays
green while its numbers hold steady, and shows up under `candidates` instead.

**Parseability is checked separately.** CodeComplexity parses with
`ignore_errors = true`, so a file with a syntax error is measured as though it
were correct and reports an artificially low number. A gate that stops
measuring without failing is worse than no gate.

## Setting it up in a repository

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
```

Every tracked `.jl` file must be either inside `[scope].measure` or named by an
`[[unmeasured_path]]`. A file that is neither turns the gate red. The assertion
is the point: a new top-level directory cannot fall through unmeasured and
silent.

Then take the first baselines:

```sh
julia --project=code_ratchet -e 'using CodeRatchet; CodeRatchet.main()' complexity refresh
julia --project=code_ratchet -e 'using JET, CodeRatchet; CodeRatchet.main()' jet refresh
COVERAGE_LCOV=lcov.info julia --project=code_ratchet \
  -e 'using CodeRatchet; CodeRatchet.main()' coverage refresh
```

## Using it

```sh
coderatchet complexity check              # exit 1 if any binding number rose
coderatchet complexity candidates         # rank work; never gates
coderatchet complexity refresh            # refuses if a number rose
coderatchet complexity refresh --accept-rise   # record a worse number, deliberately
```

where `coderatchet` is
`julia --project=code_ratchet -e 'using CodeRatchet; exit(CodeRatchet.main())'`.
The JET metric additionally needs `using JET` in that call, because it lives in
a package extension.

Environment: `CODERATCHET_ROOT` (repository root, default `pwd()`),
`CODERATCHET_DIR` (default `<root>/code_ratchet`), `COVERAGE_LCOV`.

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
text rather than independent authorship. See `LICENSE` for the notice.

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
