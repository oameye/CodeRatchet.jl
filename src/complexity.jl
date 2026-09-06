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

function provenance(::Complexity, root::AbstractString)
  return Dict{String,Any}(
    "metric" => "complexity",
    "tool" => "CodeComplexity",
    "aggregation" => "max_over_definitions",
    "commit" => short_commit(root),
  )
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
