using CodeComplexity:
  CodeComplexity,
  CyclomaticComplexity,
  CognitiveComplexity,
  ArgumentCountComplexity,
  measure_file

"""
    Complexity()

The CodeComplexity half of the gate. Pure syntax, so it loads nothing under
measurement and costs about a second on a small package.

Three metrics, one baseline. Each contributes two numbers per file: the
**maximum** over that file's definitions, which binds, and the sum, which does
not.

Binding on the maximum rather than the sum is the decision that makes this
gate survivable. A new helper of complexity 2 in a file whose maximum is 9
moves nothing, so ordinary work is quiet. The sum moves by 2 and would turn the
gate red, and that failure is noise. A noisy gate gets switched off, and then
it protects nothing. The sum is still recorded, because the maximum is blind to
sprawl and a ranking job needs it.
"""
struct Complexity <: Metric end

const COMPLEXITY_METRICS = (
  "cyc" => CyclomaticComplexity(),
  "cog" => CognitiveComplexity(),
  "arg" => ArgumentCountComplexity(),
)

metric_name(::Complexity) = "complexity"
binding(::Complexity) = ("cyc", "cog", "arg")
row_numbers(::Complexity) = ("cyc", "cog", "arg", "cyc_sum", "cog_sum", "arg_sum")

function provenance(::Complexity, ::AbstractString)
  return Dict{String,Any}(
    "metric" => "complexity",
    "tool" => "CodeComplexity",
    "aggregation" => "max_over_definitions",
  )
end

"""
    scoped_files(root, scope) -> Vector{String}

Tracked `.jl` files inside the measured scope, repository-relative.
"""
function scoped_files(root::AbstractString, scope)
  return [p for p in tracked_julia_files(root) if in_scope(p, scope)]
end

function measure(metric::Complexity, root::AbstractString)
  rulings = read_rulings(ratchet_dir(root))
  rows = Dict{String,Row}()
  for rel in scoped_files(root, rulings.scope)
    numbers = Dict{String,Int}()
    for (key, cc) in COMPLEXITY_METRICS
      file = measure_file(cc, joinpath(root, rel))
      values = Int[fn.value for fn in file.functions]
      numbers[key] = isempty(values) ? 0 : maximum(values)
      numbers[key * "_sum"] = file.total_value
    end
    rows[rel] = Row(numbers)
  end
  return rows
end

"""
    Definition

One definition and its measured value, for ranking work rather than gating it.
"""
struct Definition
  path::String
  name::String
  line::Int
  key::String
  value::Int
end

function Base.show(io::IO, d::Definition)
  return print(io, d.path, ":", d.line, " ", d.name, " ", d.key, "=", d.value)
end

"""
    candidates(root; dir) -> Vector{Definition}

Definitions standing above their threshold in `rulings.toml`, worst first.

Thresholds are deliberately kept out of the pass rule. The ratchet stops
decay; driving improvement is a separate, paced job. So a file far above every
threshold stays green while its numbers hold steady, and shows up here instead.
"""
function candidates(root::AbstractString=pwd(); dir::AbstractString=ratchet_dir(root))
  rulings = read_rulings(dir)
  names = Dict("cyc" => "cyclomatic", "cog" => "cognitive", "arg" => "argcount")
  found = Definition[]
  for rel in scoped_files(root, rulings.scope)
    for (key, cc) in COMPLEXITY_METRICS
      threshold = get(rulings.thresholds, names[key], typemax(Int))
      for fn in measure_file(cc, joinpath(root, rel)).functions
        fn.value > threshold &&
          push!(found, Definition(rel, String(fn.name), fn.line, key, fn.value))
      end
    end
  end
  sort!(found; by=d -> -d.value)
  return found
end
