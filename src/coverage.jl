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

An exemption never touches the binding number. It is a claim about specific
lines in a specific definition, held to its exact count in both directions, and
lowering the number it stands for is the only way to lower the ratchet.
"""
struct Coverage <: Metric end

metric_name(::Coverage) = "coverage"
binding(::Coverage) = ("misses",)
row_numbers(::Coverage) = ("lines", "misses")

function provenance(::Coverage, root::AbstractString)
  return Dict{String,Any}(
    "metric" => "coverage",
    "source" => "lcov",
    "attribution" => "top_level_definition_ranges",
    "commit" => short_commit(root),
  )
end

"""
    lcov_path(root) -> String

Where the gate looks for the tracefile. `COVERAGE_LCOV` overrides it, which is
how a CI job hands over the file it downloaded from the test job's artifact.
"""
lcov_path(root::AbstractString) = get(ENV, "COVERAGE_LCOV", joinpath(root, "lcov.info"))

"""
    parse_lcov(path, root) -> Dict{String,Dict{Int,Int}}

The `DA:<line>,<count>` records, per repository-relative source file.

Coverage.jl writes `SF`, `DA`, `LH`, `LF` and `end_of_record` and no function
records at all, so a line is the only unit there is. A line with no `DA` record
is not executable and is never counted.
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
      current = relative_to(strip(line[4:end]), root)
      get!(hits, current, Dict{Int,Int}())
    elseif startswith(line, "DA:") && !isempty(current)
      body = strip(line[4:end])
      comma = findfirst(==(','), body)
      comma === nothing && continue
      number = tryparse(Int, body[1:(comma - 1)])
      count = tryparse(Int, body[(comma + 1):end])
      (number === nothing || count === nothing) && continue
      table = hits[current]
      # A file measured by more than one session appears twice. The hits add
      # up, so a line covered by either session is covered.
      table[number] = get(table, number, 0) + count
    elseif startswith(line, "end_of_record")
      current = ""
    end
  end
  return hits
end

"""
    relative_to(path, root) -> String

An `SF:` record's path as a repository-relative one. Coverage.jl writes the
path it was given, so it may be absolute or relative depending on where
`julia-processcoverage` ran.
"""
function relative_to(path::AbstractString, root::AbstractString)
  p = replace(String(path), '\\' => '/')
  base = replace(abspath(root), '\\' => '/')
  base = endswith(base, "/") ? base : base * "/"
  startswith(p, base) && (p = p[(length(base) + 1):end])
  return startswith(p, "./") ? p[3:end] : p
end

# --- attributing a miss to a definition ------------------------------------
#
# A per-file miss count cannot see a leak inside an exempted definition: a line
# covered elsewhere in the file pays for a newly uncovered line inside the
# exemption, and the file total stays flat. Attributing each miss to the
# definition holding it is what lets an exemption be held to an exact count.

"""
The name a miss carries when it lies inside no named top-level definition. A
`const`, an `include` and a `precompile` block all land here, and it is a
legitimate exemption target.
"""
const TOPLEVEL = "<toplevel>"

defname(x::Symbol) = String(x)
defname(x::QuoteNode) = defname(x.value)
# A docstring parses to `Expr(:macrocall, GlobalRef(Core, Symbol("@doc")), …)`,
# and a GlobalRef is neither a Symbol nor an Expr. Without this method every
# documented definition falls to the default and is attributed to <toplevel>.
defname(x::GlobalRef) = defname(x.name)
defname(::Any) = ""
function defname(e::Expr)
  isempty(e.args) && return ""
  oneof(e.head, (:call, :where, :(<:), :curly, :macrocall)) && return defname(e.args[1])
  oneof(e.head, (:(::), :.)) && return defname(e.args[end])
  return ""
end

"""
    unwrap(e)

Drop a docstring wrapper, since a documented definition would otherwise be
named after the doc macro. Nearly every public definition is documented, so
this is not a corner case.
"""
function unwrap(e)
  if e isa Expr && e.head === :macrocall && defname(e.args[1]) == "@doc"
    return unwrap(e.args[end])
  end
  return e
end

"""
    definition_name(e) -> String

The name an exemption row writes for one top-level expression, or `""` when the
expression declares nothing a reader would name.
"""
function definition_name(e0)
  e = unwrap(e0)
  e isa Expr || return ""
  if oneof(e.head, (:function, :macro))
    return defname(e.args[1])
  elseif e.head === :(=) && e.args[1] isa Expr && oneof(e.args[1].head, (:call, :where))
    return defname(e.args[1])
  elseif e.head === :struct
    return length(e.args) >= 2 ? defname(e.args[2]) : ""
  elseif oneof(e.head, (:abstract, :primitive))
    return isempty(e.args) ? "" : defname(e.args[1])
  elseif e.head === :const
    return e.args[1] isa Expr ? defname(e.args[1].args[1]) : defname(e.args[1])
  elseif e.head === :macrocall
    # A macro that wraps a definition names the definition, not the macro:
    # naming the macro would collapse every call in a file onto one key.
    inner = definition_name(e.args[end])
    return isempty(inner) ? defname(e.args[1]) : inner
  end
  return ""
end

function line_numbers!(acc::Vector{Int}, e)
  if e isa LineNumberNode
    push!(acc, e.line)
  elseif e isa Expr
    for a in e.args
      line_numbers!(acc, a)
    end
  end
  return acc
end

"""
    definition_ranges(root, rel) -> Vector{Tuple{String,Int,Int}}

One entry per named top-level definition: its name and the first and last
source line it holds.

The range comes from the `LineNumberNode`s the parser leaves in the expression,
and every executable line carries one, so a miss always falls inside the range
of the definition holding it. The walk is top-level only: a closure inside a
function is attributed to that function, because an exemption is written and
read by a human and a human names the method.
"""
function definition_ranges(root::AbstractString, rel::AbstractString)
  out = Tuple{String,Int,Int}[]
  top = try
    Meta.parseall(read(joinpath(root, rel), String); filename=rel)
  catch
    return out
  end
  top isa Expr || return out
  for a in top.args
    a isa Expr || continue
    name = definition_name(a)
    isempty(name) && continue
    lines = line_numbers!(Int[], a)
    isempty(lines) && continue
    push!(out, (name, minimum(lines), maximum(lines)))
  end
  return out
end

"""
    misses_by_definition(root, rel, table) -> Dict{String,Int}

Uncovered lines in one file, grouped by the definition holding them.

A line inside more than one range is attributed to the innermost, so a
definition nested in another does not double count.
"""
function misses_by_definition(
  root::AbstractString, rel::AbstractString, table::Dict{Int,Int}
)
  ranges = definition_ranges(root, rel)
  counts = Dict{String,Int}()
  for (line, hits) in table
    iszero(hits) || continue
    best, width = TOPLEVEL, typemax(Int)
    for (name, first_line, last_line) in ranges
      first_line <= line <= last_line || continue
      span = last_line - first_line
      span < width && ((best, width) = (name, span))
    end
    counts[best] = get(counts, best, 0) + 1
  end
  return counts
end

# --- exemptions -------------------------------------------------------------

"""
    exemptions(rulings) -> Dict{String,Dict{String,Int}}

The `[[exemption]]` rows, keyed by path and then by definition.

A row states how many uncovered lines in that definition may stand, so the
count is part of the claim rather than a free pass on the whole definition.
"""
function exemptions(rulings::Rulings)
  out = Dict{String,Dict{String,Int}}()
  for entry in get(rulings.raw, "exemption", Dict[])
    for field in ("path", "definition", "misses", "reason")
      haskey(entry, field) || error(
        "every [[exemption]] needs `path`, `definition`, `misses` and `reason`; got $(entry)",
      )
    end
    table = get!(out, String(entry["path"]), Dict{String,Int}())
    name = String(entry["definition"])
    table[name] = get(table, name, 0) + Int(entry["misses"])
  end
  return out
end

function measure(::Coverage, root::AbstractString; dir::AbstractString=ratchet_dir(root))
  rulings = read_rulings(dir)
  measured = parse_lcov(lcov_path(root), root)
  rows = Dict{String,Row}()
  for rel in scoped_files(root, rulings.scope)
    table = get(measured, rel, Dict{Int,Int}())
    rows[rel] = Row(
      Dict("lines" => length(table), "misses" => count(iszero, values(table)))
    )
  end
  return rows
end

"""
    ruling_failures(::Coverage, root) -> Vector{String}

An exemption is held to its exact count in **both** directions.

A claim above the truth is stale: the lines were covered and the row outlived
its reason. A claim below it is the leak a file total cannot see, because a
line covered elsewhere in the file pays for a new uncovered line inside the
exempted definition and the ratchet reads a flat number. Equality closes both.
"""
function ruling_failures(::Coverage, root::AbstractString, dir::AbstractString)
  rulings = read_rulings(dir)
  ruled = exemptions(rulings)
  isempty(ruled) && return String[]
  measured = parse_lcov(lcov_path(root), root)
  bad = String[]
  for path in sort(collect(keys(ruled)))
    table = get(measured, path, Dict{Int,Int}())
    actual = misses_by_definition(root, path, table)
    for name in sort(collect(keys(ruled[path])))
      claimed, truth = ruled[path][name], get(actual, name, 0)
      claimed == truth && continue
      push!(
        bad,
        "$path: the exemption for `$name` claims $claimed uncovered line(s) but " *
        "$truth remain. " *
        (
          if claimed > truth
            "Lower or remove the ruling."
          else
            "Cover the new one, or raise the ruling with its reason."
          end
        ),
      )
    end
  end
  return bad
end

"""
    entry_failures(::Coverage, root, paths, rows) -> Vector{String}

A file entering with no baseline row enters fully covered or fully exempted.

Coverage is the one metric with a meaningful, reachable zero, so a new file has
no excuse to arrive with unexplained misses.
"""
function entry_failures(::Coverage, root::AbstractString, paths, context::EntryContext)
  isempty(paths) && return String[]
  rulings = read_rulings(context.dir)
  ruled = exemptions(rulings)
  measured = parse_lcov(lcov_path(root), root)
  bad = String[]
  for path in sort(collect(paths))
    table = get(measured, path, Dict{Int,Int}())
    actual = misses_by_definition(root, path, table)
    claimed = get(ruled, path, Dict{String,Int}())
    remainder = sum(max(0, n - get(claimed, name, 0)) for (name, n) in actual; init=0)
    remainder > 0 && push!(
      bad,
      "$path enters with $remainder uncovered line(s) that no exemption accounts for. " *
      "Cover them, or add an [[exemption]] row naming the definition and the count.",
    )
  end
  return bad
end

"""
    terminal(root; dir) -> Vector{String}

The files still short of zero misses, worst first. The terminal condition the
map drives toward, which the ratchet alone never reports.
"""
function terminal(root::AbstractString=pwd(); dir::AbstractString=ratchet_dir(root))
  rows = measure(Coverage(), root; dir)
  short = [(p, r["misses"]) for (p, r) in rows if r["misses"] > 0]
  sort!(short; by=x -> -x[2])
  return ["$p: $n miss(es)" for (p, n) in short]
end
