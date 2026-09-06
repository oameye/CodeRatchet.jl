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

Three metrics, one baseline. Each contributes three numbers per file: the
**maximum** over that file's definitions and the **count of definitions above
the threshold**, both binding, and the sum, which does not.

Binding on the maximum rather than the sum is the decision that makes this
gate survivable. A new helper of complexity 2 in a file whose maximum is 9
moves nothing, so ordinary work is quiet. The sum moves by 2 and would turn the
gate red, and that failure is noise. A noisy gate gets switched off, and then
it protects nothing. The sum is still recorded, because the maximum is blind to
sprawl and a ranking job needs it.

The maximum alone leaves one hole, and the count closes it. A file sitting at
18 absorbs a brand new definition at 17 without moving: the maximum is
unchanged, the gate reports PASS, and that file now has two bad definitions
where it had one. Counting how many stand above the threshold makes the second
one visible while staying quiet about the helper at 2.

This does not make the threshold a pass rule. The count is ratcheted like every
other number here, so a file with five definitions above the threshold stays
green at five and goes red at six. The threshold decides what counts as bad;
the ratchet still decides what fails.
"""
struct Complexity <: Metric end

const COMPLEXITY_METRICS = (
  "cyc" => CyclomaticComplexity(),
  "cog" => CognitiveComplexity(),
  "arg" => ArgumentCountComplexity(),
)

metric_name(::Complexity) = "complexity"
binding(::Complexity) = ("cyc", "cog", "arg", "cyc_over", "cog_over", "arg_over")
function row_numbers(::Complexity)
  return (
    "cyc", "cog", "arg", "cyc_over", "cog_over", "arg_over", "cyc_sum", "cog_sum", "arg_sum"
  )
end

"""
The `[thresholds]` key each complexity metric reads, for the count of
definitions standing above it.
"""
const COMPLEXITY_THRESHOLDS = Dict(
  "cyc" => "cyclomatic", "cog" => "cognitive", "arg" => "argcount"
)

function provenance(::Complexity, root::AbstractString)
  return Dict{String,Any}(
    "metric" => "complexity",
    "tool" => "CodeComplexity",
    # Changed when the count of definitions above threshold was added. An older
    # baseline carries the previous value and fails provenance, which says what
    # happened; without the change it would instead produce a wall of
    # violations for numbers that had never been recorded.
    "aggregation" => "max_and_count_over_threshold",
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
      threshold = get(rulings.thresholds, COMPLEXITY_THRESHOLDS[key], 0)
      numbers[key] = isempty(values) ? 0 : maximum(values)
      # An unset threshold counts nothing rather than counting everything: zero
      # would otherwise read as "every definition is above it".
      numbers[key * "_over"] = threshold > 0 ? count(>(threshold), values) : 0
      numbers[key * "_sum"] = file.total_value
    end
    rows[rel] = Row(numbers)
  end
  return rows
end
