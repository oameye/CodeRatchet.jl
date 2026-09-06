"""
    Coverage()

The line-coverage half of the gate. Reads an `lcov.info`, which
`julia-actions/julia-processcoverage` writes in the test job, so it loads
nothing under measurement.

A file's **miss count** binds and its relevant-line count is context, the same
split `Complexity` draws between a maximum and a sum.

The percentage is deliberately not the metric. It rises when an uncovered line
is deleted and it rises when a covered one is added, so a file can improve its
percentage while gaining misses. The miss count is the number that goes to
zero, and it moves in the right direction on its own: adding a covered
function raises `lines` and leaves `misses` alone, so ordinary work is quiet.
"""
struct Coverage <: Metric end

metric_name(::Coverage) = "coverage"
binding(::Coverage) = ("misses",)
row_numbers(::Coverage) = ("lines", "misses", "exempt")
strict_new(::Coverage) = true

function provenance(::Coverage, ::AbstractString)
  return Dict{String,Any}(
    "metric" => "coverage", "source" => "lcov", "binding_is" => "unexempted_misses"
  )
end

"""
    lcov_path(root) -> String

Where the gate looks for the tracefile. `COVERAGE_LCOV` overrides it, which is
how a CI job hands over the file it downloaded from the test job's artifact.
"""
lcov_path(root::AbstractString) = get(ENV, "COVERAGE_LCOV", joinpath(root, "lcov.info"))

"""
    parse_lcov(path, root) -> Dict{String,Tuple{Int,Int}}

Repository-relative path to `(relevant_lines, misses)`.

A file appearing in several records is accumulated rather than replaced, since
a parallel test run can emit one record per worker.
"""
function parse_lcov(path::AbstractString, root::AbstractString)
  isfile(path) || error(
    "no lcov tracefile at $path. Run the tests with `--code-coverage=user` and " *
    "process them, or point COVERAGE_LCOV at the file.",
  )
  hits = Dict{String,Dict{Int,Int}}()
  current = ""
  for line in eachline(path)
    if startswith(line, "SF:")
      file = line[4:end]
      rel = replace(
        relpath(isabspath(file) ? file : joinpath(root, file), root), '\\' => '/'
      )
      current = rel
      get!(hits, current, Dict{Int,Int}())
    elseif startswith(line, "DA:") && !isempty(current)
      body = line[4:end]
      comma = findfirst(==(','), body)
      comma === nothing && continue
      number = tryparse(Int, body[1:(comma - 1)])
      count = tryparse(Int, body[(comma + 1):end])
      (number === nothing || count === nothing) && continue
      table = hits[current]
      table[number] = get(table, number, 0) + count
    elseif startswith(line, "end_of_record")
      current = ""
    end
  end
  out = Dict{String,Tuple{Int,Int}}()
  for (file, table) in hits
    out[file] = (length(table), count(iszero, values(table)))
  end
  return out
end

"""
    exempt_counts(rulings) -> Dict{String,Int}

Lines a human has ruled unreachable, per file.

An exemption states the exact count it stands for. That is what stops it
becoming a blanket: the count is checked against the measurement, so an
exemption that has outgrown its reason shows up as a stale ruling rather than
silently absorbing new misses.
"""
function exempt_counts(rulings::Rulings)
  counts = Dict{String,Int}()
  for entry in rulings.exemptions
    haskey(entry, "path") && haskey(entry, "misses") || error(
      "every [[exemption]] needs a `path`, a `misses` count and a `reason`; " *
      "got $(entry)",
    )
    path = String(entry["path"])
    counts[path] = get(counts, path, 0) + Int(entry["misses"])
  end
  return counts
end

function measure(metric::Coverage, root::AbstractString)
  rulings = read_rulings(ratchet_dir(root))
  measured = parse_lcov(lcov_path(root), root)
  exempt = exempt_counts(rulings)
  rows = Dict{String,Row}()
  for rel in scoped_files(root, rulings.scope)
    lines, misses = get(measured, rel, (0, 0))
    allowed = get(exempt, rel, 0)
    rows[rel] = Row(
      Dict("lines" => lines, "misses" => max(0, misses - allowed), "exempt" => allowed)
    )
  end
  return rows
end

"""
    stale_exemptions(root; dir) -> Vector{String}

Exemptions claiming more unreachable lines than the file actually misses.

An exemption is a claim about specific code. When the code changes under it the
claim expires, and an expired exemption quietly widens the gate.
"""
function stale_exemptions(root::AbstractString=pwd(); dir::AbstractString=ratchet_dir(root))
  rulings = read_rulings(dir)
  measured = parse_lcov(lcov_path(root), root)
  stale = String[]
  for (path, allowed) in exempt_counts(rulings)
    _, misses = get(measured, path, (0, 0))
    misses < allowed && push!(
      stale,
      "$path exempts $allowed miss(es) but only $misses remain; lower or remove the ruling",
    )
  end
  return sort(stale)
end
