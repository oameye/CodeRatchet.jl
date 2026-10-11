"""
    CodeRatchet

Rank the worst code in a Julia package, from the REPL.

Load it the way you load Cthulhu or Profile, point it at a package, and work
the numbers down. Nothing is configured, stored or compared: every call
measures the code as it stands and returns [`Findings`](@ref), worst first.

```julia
using CodeRatchet
complexity(MyPkg)      # definitions ranked by cyclomatic complexity
style(MyPkg)           # house-rule breaches, with line numbers
docstrings(MyPkg)      # public names with no docstring
boxes(MyPkg)           # captured variables the compiler could not type
coverage(MyPkg)        # definitions with uncovered lines
report(MyPkg)          # the first four, top of each
```

Every function reports facts, not verdicts: a number, a file and a line. A
finding is either true of the code or it is a bug here. There are no
thresholds that pass or fail and nothing to dismiss.

Adapted from the `code_health/` directory of PortfolioOptimisers.jl by Daniel
Celis Garza (MIT). See LICENSE.
"""
module CodeRatchet

using CoverageTools: CoverageTools
using JuliaSyntax: JuliaSyntax
using CodeComplexity:
  ArgumentCountComplexity, CognitiveComplexity, CyclomaticComplexity, measure_file

export Findings, boxes, complexity, coverage, docstrings, report, style

include("findings.jl")
include("syntax.jl")
include("complexity.jl")
include("style.jl")
include("docstrings.jl")
include("boxes.jl")
include("coverage.jl")
include("report.jl")

end
