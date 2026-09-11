"""
    CodeRatchetColdStartExt

The paired cold-start experiment, kept behind `Pkg` so ordinary CodeRatchet
loading and precompilation do not pay for the timing harness.
"""
module CodeRatchetColdStartExt

using CodeRatchet: CodeRatchet, Metric, RULINGS, is_ci, read_rulings, step_summary
import CodeRatchet: coldstart_compare, coldstart_main
using TOML: TOML

include("../src/coldstart.jl")
include("../src/coldstart_cli.jl")

end # module CodeRatchetColdStartExt
