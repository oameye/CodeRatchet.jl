# CodeRank.jl

Rank the worst code in a Julia package, from the REPL.

Load it the way you load Cthulhu or Profile, point it at a package, and work the
numbers down. There is nothing to configure, store or compare: every call
measures the code as it stands and returns `Findings`, worst first.

```julia
using CodeRank

complexity(MyPkg)    # definitions ranked by cyclomatic complexity
style(MyPkg)         # house-rule breaches, with the source line
docstrings(MyPkg)    # public names with no docstring
boxes(MyPkg)         # captured variables the compiler could not type
coverage(MyPkg)      # definitions with uncovered lines (runs the tests)
report(MyPkg)        # the first four, top five of each
```

`MyPkg` is a loaded package module or a directory path. Results are
`AbstractVector`s of `Finding(file, line, what, value, detail)`, so `first`,
`filter`, `sum` and `sort` work, and the REPL shows the top 20.

```
julia> complexity(CodeRank)
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
| `complexity(target; by=:cyclomatic, over=1)` | every definition, ranked by `:cyclomatic`, `:cognitive` or `:arguments`; `over` only hides low values | ~1 s |
| `style(target; rules=...)` | `:union_nothing`, `:underscore_name`, `:implicit_kwarg`, one finding per line | ~1 s |
| `docstrings(target)` | names declared public (`export`, `public`, `@public`) with no docstring anywhere in the package | ~1 s |
| `boxes(mod; root=...)` | `Core.Box` captures per method, with the variable's name, from lowered code | seconds |
| `coverage(target; lcov=nothing)` | definitions with uncovered lines; runs `Pkg.test` with coverage unless you pass a tracefile | test time |

`paths=["src", "ext"]` sets what is measured. A file that does not parse is an
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
Pkg.add(url="https://github.com/oameye/CodeRatchet.jl")  # repo not renamed yet
```

Needs Julia 1.12 or later.

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

This package was called CodeRatchet while it was a per-file ratchet, a gate that
fails when a number rises above a stored baseline. That design is in the git history before this branch.
