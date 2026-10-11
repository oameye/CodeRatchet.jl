"""
    parse_lcov(path, root) -> Dict{String,Dict{Int,Int}}

The `DA:<line>,<count>` records, per source file relative to `root`. A line with
no `DA` record is not executable and is never counted.
"""
function parse_lcov(path::AbstractString, root::AbstractString)
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
      # A file measured by more than one process appears twice, and the hits add
      # up, so a line covered by either is covered.
      table[number] = get(table, number, 0) + count
    elseif startswith(line, "end_of_record")
      current = ""
    end
  end
  return hits
end

"""
The name a miss carries when it lies inside no named top-level definition: a
`const`, an `include`, a `precompile` block.
"""
const TOPLEVEL = "<toplevel>"

function line_numbers!(acc::Vector{Int}, e)
  if e isa LineNumberNode
    push!(acc, e.line)
  elseif e isa Expr
    foreach(a -> line_numbers!(acc, a), e.args)
  end
  return acc
end

# One entry per named top-level definition: its name and the first and last
# source line it holds. A closure inside a function belongs to that function, and
# a `module` block is walked through so a single-file package is not one big
# definition.
function definition_ranges(root::AbstractString, rel::AbstractString)
  out = Tuple{String,Int,Int}[]
  add_ranges!(out, parse_file(root, rel).args)
  return out
end

function add_ranges!(out, args)
  start = 0
  for a in args
    if a isa LineNumberNode
      start = a.line
    elseif a isa Expr && a.head === :module
      add_ranges!(out, a.args[end].args)
    elseif a isa Expr
      name = definition_name(a)
      isempty(name) && continue
      # The line before the definition is where it starts, and for a one-line
      # method it is the only line there is.
      lines = line_numbers!(start > 0 ? [start] : Int[], a)
      isempty(lines) && continue
      push!(out, (name, minimum(lines), maximum(lines)))
    end
  end
  return nothing
end

# Uncovered lines of one file, grouped by the innermost definition holding them.
function misses_by_definition(root::AbstractString, rel::AbstractString, table)
  ranges = definition_ranges(root, rel)
  found = Dict{String,Vector{Int}}()
  for (line, hits) in table
    iszero(hits) || continue
    best, width = TOPLEVEL, typemax(Int)
    for (name, first_line, last_line) in ranges
      first_line <= line <= last_line || continue
      span = last_line - first_line
      span < width && ((best, width) = (name, span))
    end
    push!(get!(found, best, Int[]), line)
  end
  return found
end

"""
    with_unrun_code(path, table) -> Dict{Int,Int}

Add a zero for every line of code that never ran.

Julia records a line only once its method has been compiled, so a function
nothing ever called has no record at all and would read as absent, not as
uncovered. CoverageTools reads the source to find those lines, which is the same
step `julia-processcoverage` applies in CI.
"""
function with_unrun_code(path::AbstractString, table::Dict{Int,Int})
  counts = Vector{Union{Nothing,Int}}(nothing, countlines(path))
  for (line, hits) in table
    1 <= line <= length(counts) && (counts[line] = hits)
  end
  CoverageTools.amend_coverage_from_src!(counts, path)
  return Dict{Int,Int}(i => c for (i, c) in enumerate(counts) if c !== nothing)
end

"""
Run the package's tests with line coverage and return the LCOV file's path,
inside a fresh temporary directory so no earlier run can contaminate it.
"""
function run_coverage(root::AbstractString)
  lcov = joinpath(mktempdir(), "lcov.info")
  code = "using Pkg; Pkg.test(; coverage=$(repr(lcov)))"
  # A child started from inside another `Pkg.test` inherits its sandboxed load
  # path, and would then fail to find the package under test.
  cmd = `$(Base.julia_cmd()) --startup-file=no --project=$root -e $code`
  Base.run(addenv(cmd, "JULIA_LOAD_PATH" => nothing, "JULIA_PROJECT" => nothing))
  isfile(lcov) || error("the test run wrote no coverage file at $lcov")
  return lcov
end

"""
    coverage(target=pwd(); lcov=nothing, paths=["src", "ext"])

Every definition with uncovered lines, most uncovered first, at its first
uncovered line.

With no `lcov`, this runs the package's tests with coverage in a child Julia
process (`Pkg.test`), so the result is never stale. Pass `lcov` to read a
tracefile you already have, for example one CI downloaded. Coverage is line
execution data: it says a line ran, not that anything checked the result.
"""
function coverage(target=pwd(); lcov=nothing, paths=["src", "ext"])
  root = package_root(target)
  files = source_files(root, paths)
  path = lcov === nothing ? run_coverage(root) : String(lcov)
  isfile(path) || throw(ArgumentError("no lcov tracefile at $path"))
  hits = parse_lcov(path, root)
  items = Finding[]
  for rel in files
    haskey(hits, rel) || continue
    table = with_unrun_code(joinpath(root, rel), hits[rel])
    for (name, lines) in misses_by_definition(root, rel, table)
      sort!(lines)
      push!(
        items,
        Finding(
          rel, first(lines), name, length(lines), "uncovered lines: $(join(lines, ", "))"
        ),
      )
    end
  end
  return ranked("coverage", items)
end
