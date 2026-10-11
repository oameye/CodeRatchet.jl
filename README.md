# CodeRatchet.jl

Rank the worst code in a Julia package, from the REPL.

Load it the way you load Cthulhu or Profile, point it at a package, and work the
numbers down. There is nothing to configure, store or compare: every call
measures the code as it stands and returns `Findings`, worst first.

```julia
using CodeRatchet

complexity(MyPkg)    # definitions ranked by cyclomatic complexity
style(MyPkg)         # house-rule breaches, with the source line
docstrings(MyPkg)    # public names with no docstring
boxes(MyPkg)         # captured variables the compiler could not type
coverage(MyPkg)      # definitions with uncovered lines (runs the tests)
report(MyPkg)        # the first four, top five of each

invalidations(MyPkg; workload="...")  # methods that made compiled code stale
triggers(MyPkg; workload="...")       # compiler work a workload still pays for
image(MyPkg)                          # what the precompiled image holds
```

`MyPkg` is a loaded package module or a directory path. Results are
`AbstractVector`s of `Finding(file, line, what, value, detail)`, so `first`,
`filter`, `sum` and `sort` work, and the REPL shows the top 20.

```
julia> complexity(CodeRatchet)
complexity (cyclomatic): 59 findings, worst 20
  src/style.jl:99      12  sig_lines!
  src/syntax.jl:142    12  definition_name
  ...
```

## Facts, not verdicts

Each function reports a number, a file and a line. There are no thresholds that
pass or fail and nothing to dismiss, so a finding is either true of the code or
it is a bug in this package. That rules some things out on purpose: no JET or
JETLS wrapper (their reports have false positives; run them directly), no regex
style rules, no baselines, no config files.

| Function | What it reports | Cost |
| --- | --- | --- |
| `complexity(target; by=:cyclomatic, over=1)` | every definition, ranked by `:cyclomatic`, `:cognitive` or `:arguments` (parameter count, read from the syntax tree, return annotations included); `over` only hides low values | ~1 s |
| `style(target; rules=...)` | `:union_nothing`, `:underscore_name`, `:implicit_kwarg`, one finding per line | ~1 s |
| `docstrings(target)` | names declared public (`export`, `public`, `@public`) with no docstring anywhere in the package | ~1 s |
| `boxes(mod; root=...)` | `Core.Box` captures per method, with the variable's name, from lowered code | seconds |
| `coverage(target; lcov=nothing)` | definitions with uncovered lines; runs `Pkg.test` with coverage unless you pass a tracefile | test time |

### Compiler facts

The last three look at what the compiler did, so they run in a fresh Julia
process. Loading the analyser first would change the events it is meant to
explain, so the child holds only the collector until the capture ends. The
snoop tooling (SnoopCompileCore, SnoopCompile, PkgCacheInspector) lives in a
shared environment named `coderatchet` under your depot, created on first use
and never added to the package you measure. The package's own environment must
be instantiated, as it is when you develop it.

| Function | What it reports |
| --- | --- |
| `invalidations(target; workload=nothing, owners=[], all=false)` | each method defined during load (and `workload`) that invalidated compiled code, ranked by how many MethodInstances it invalidated, with roots and cascade depth. Only methods the package owns by default, so a dependency's cascade is not charged to you; `owners` names more, `all=true` lists everything with its owner. |
| `triggers(target; workload, owners=[], owned_only=false)` | each specialization that still entered inference when `workload` ran against the built image, ranked by inclusive inference time (µs). The set of signatures is exact; the time is a measurement. Precompiling a signature removes its trigger. |
| `image(target; owned_only=false)` | the precompiled image read before the package loads: file bytes, segment sizes, counts of external methods, specializations, roots and edges, and every method the image specialized with how many specializations it holds. |

`workload` is Julia code evaluated in the child. None of these says an image is
too big or a cascade too deep: a larger image can be a faster one. The
signatures are spelled the same way in all three, so a trigger can be looked up
in `image` and an invalidated method in `triggers`. Invalidation logging and
lowering change between Julia releases, so the results are true for the running
version only.

`paths=["src", "ext"]` sets what is measured by the source-level metrics. A file that does not parse is an
error, never a zero.

Notes on exactness:

- `boxes` reads lowering, which changes between Julia releases (1.12 stopped
  boxing a capture reassigned before the closure is built), so the result is
  true for the running version only. It needs the module loaded, and Julia 1.12
  or later for `Base.visit`.
- `coverage` is line execution data, not proof that anything checked a result.
  Julia records no line for a method that never compiled, so unrun code is
  added back from the source with CoverageTools, as `julia-processcoverage`
  does in CI.
- `docstrings` counts a name documented anywhere in the package as documented,
  because a function with methods in four files is documented once.

## Installing

Not registered. Install it once into your global environment:

```julia
using Pkg
Pkg.add(url="https://github.com/oameye/CodeRatchet.jl")
```

Needs Julia 1.13 or later (the code runs on 1.12, which is no longer tested).

## Prior art

The metrics and several of the decisions behind them come from the
`code_health/` directory of
[PortfolioOptimisers.jl](https://github.com/dcelisgarza/PortfolioOptimisers.jl)
by Daniel Celis Garza (MIT), described in [this Discourse
post](https://discourse.julialang.org/t/idiomatic-julia-code-in-ai-generated-code/139183/4).
The per-definition coverage attribution, the public-name rule behind
`docstrings` and the syntax-tree style rules are his; several docstrings
paraphrase his rationale closely enough to be derived text. `boxes` is derived
from `contrib/scan-closure-boxes.jl` in JuliaLang/julia (MIT). `LICENSE`
itemises all of it.

Before this rework the package was a per-file ratchet, a gate that fails when a
number rises above a stored baseline. The name stayed. That design is in the git history before this branch.
