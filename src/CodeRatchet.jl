"""
    CodeRatchet

A per-file ratchet for Julia code-quality metrics.

The ratchet is the whole idea: a number only has to stop getting worse. That is
what makes it adoptable on a codebase where the absolute bar is out of reach
today, which an absolute gate never is.

One deep module, three thin adapters. [`ratchet`](@ref) compares a measurement
against a baseline and knows nothing about complexity, coverage or inference; a
[`Metric`](@ref) says how to produce rows and which of their numbers bind.
"""
module CodeRatchet

using TOML: TOML
using JuliaSyntax: JuliaSyntax

export Complexity, Coverage, check, refresh

# --- what a measurement is -------------------------------------------------

"""
    Row

Every number one metric records for one file.

A row carries more numbers than bind. A non-binding number is context: it is
written to the baseline, it is used to pair a rename, and it never turns the
gate red on its own.
"""
struct Row
  numbers::Dict{String,Int}
end

Row(pairs::Pair{String,Int}...) = Row(Dict(pairs))

Base.getindex(row::Row, key::AbstractString) = row.numbers[key]
Base.get(row::Row, key::AbstractString, default) = get(row.numbers, key, default)

# A row is a value, not an identity. Without these, the default `==` falls back
# to `===` on the wrapped Dict, so a row read back from a baseline never equals
# the numerically identical row that was written.
Base.:(==)(a::Row, b::Row) = a.numbers == b.numbers
Base.hash(row::Row, h::UInt) = hash(row.numbers, hash(:Row, h))

"""
    Metric

A thing that can be measured per file and ratcheted.

An implementation provides `metric_name`, `binding`, `row_numbers`,
`measure` and `provenance`. Nothing else in this package knows what the
numbers mean.
"""
abstract type Metric end

"""
    metric_name(metric) -> String

Baseline filename stem, so `Complexity()` writes `complexity_baseline.toml`.
"""
function metric_name end

"""
    binding(metric) -> Tuple{Vararg{String}}

The numbers the ratchet compares. A rise in one of these is a violation.
"""
function binding end

"""
    row_numbers(metric) -> Tuple{Vararg{String}}

Every number a row carries, binding or not. A rename pairs on all of them,
which is stricter than pairing on the binding subset alone and so cannot pair
two files that merely share a worst definition.
"""
function row_numbers end

"""
    measure(metric, root) -> Dict{String,Row}

Measure `root`, keyed by repository-relative path with `/` separators.
"""
function measure end

"""
    provenance(metric, root) -> Dict{String,Any}

What the run depended on. Written into the baseline and asserted on read, so a
baseline is never compared against a run that measured a different thing.

Takes `root` because a metric may need the rulings to answer: JET's provenance
records which package it analysed and under which load set, and both live in
`rulings.toml`.
"""
provenance(::Metric, ::AbstractString) = Dict{String,Any}()

"""
    strict_new(metric) -> Bool

Whether a file absent from the baseline must enter clean. `false` lets a new
file enter at whatever it measures, which is right when the metric has no
natural zero. Coverage overrides it: an added file enters fully covered or
exempted, because there the zero is meaningful and reachable.
"""
strict_new(::Metric) = false

# --- the rulings file ------------------------------------------------------

const RULINGS = "rulings.toml"

"""
    Rulings

The hand-written half of the gate. Nothing here is measured, and no script in
this package ever rewrites this file. That split is the point: no human
paragraph shares a file that a refresh overwrites.
"""
struct Rulings
  thresholds::Dict{String,Int}
  scope::Vector{String}
  unmeasured::Vector{String}
  exemptions::Vector{Dict{String,Any}}
  raw::Dict{String,Any}
end

function read_rulings(dir::AbstractString)
  path = joinpath(dir, RULINGS)
  isfile(path) || error(
    "$path not found. Every gate needs its hand-written half; see the " *
    "CodeRatchet README for a starting template.",
  )
  raw = TOML.parsefile(path)
  thresholds = Dict{String,Int}(k => Int(v) for (k, v) in get(raw, "thresholds", Dict()))
  scope = String[
    String(p) for p in get(get(raw, "scope", Dict()), "measure", ["src/", "ext/"])
  ]
  unmeasured = String[
    String(entry["path"]) for entry in get(raw, "unmeasured_path", Dict[])
  ]
  exemptions = Dict{String,Any}[entry for entry in get(raw, "exemption", Dict[])]
  return Rulings(thresholds, scope, unmeasured, exemptions, raw)
end

# --- the baseline file -----------------------------------------------------

function baseline_path(metric::Metric, dir::AbstractString)
  return joinpath(dir, metric_name(metric) * "_baseline.toml")
end

function read_baseline(metric::Metric, dir::AbstractString)
  path = baseline_path(metric, dir)
  isfile(path) || return nothing, Dict{String,Any}()
  raw = TOML.parsefile(path)
  recorded = get(raw, "provenance", Dict{String,Any}())
  rows = Dict{String,Row}()
  for (file, numbers) in get(raw, "files", Dict{String,Any}())
    rows[file] = Row(Dict{String,Int}(k => Int(v) for (k, v) in numbers))
  end
  return rows, recorded
end

function write_baseline(
  metric::Metric, dir::AbstractString, rows::Dict{String,Row}, root::AbstractString
)
  path = baseline_path(metric, dir)
  open(path, "w") do io
    println(
      io, "# Generated by CodeRatchet.jl. Every number here is measured, so this file is"
    )
    println(io, "# rewritten wholesale by `refresh` and must not be hand-edited. The human")
    println(io, "# judgements live in $RULINGS beside it.")
    println(io)
    println(io, "[provenance]")
    for (key, value) in sort(collect(provenance(metric, root)); by=first)
      println(io, key, " = ", tomlvalue(value))
    end
    println(io, "binding = ", tomlvalue(collect(binding(metric))))
    for file in sort(collect(keys(rows)))
      println(io)
      println(io, "[files.", repr(file), "]")
      row = rows[file]
      for key in row_numbers(metric)
        haskey(row.numbers, key) && println(io, key, " = ", row.numbers[key])
      end
    end
  end
  return path
end

tomlvalue(v::AbstractString) = repr(String(v))
tomlvalue(v::Integer) = string(v)
tomlvalue(v::Bool) = v ? "true" : "false"
tomlvalue(v::AbstractVector) = "[" * join(map(tomlvalue, v), ", ") * "]"

# --- the ratchet ------------------------------------------------------------

"""
    Violation

One binding number that rose. Carries both values, because a violation the
reader cannot size is a violation they cannot act on.
"""
struct Violation
  path::String
  key::String
  from::Int
  to::Int
end

function Base.show(io::IO, v::Violation)
  return print(io, v.path, ": ", v.key, " rose ", v.from, " -> ", v.to)
end

"""
    pair_renames(gone, appeared, current, baseline, keys) -> Dict{String,String}

Pair a file that vanished with one that appeared when every number matches.

Pairing on the full number set rather than the binding subset is deliberate:
two unrelated files often share a worst definition, and pairing them would
carry the wrong history forward. A pairing is taken only when it is
unambiguous in both directions.
"""
function pair_renames(gone, appeared, current, baseline, keys)
  fingerprint(row) = Int[get(row, k, -1) for k in keys]
  pairs = Dict{String,String}()
  for old in gone
    matches = [
      new for new in appeared if fingerprint(current[new]) == fingerprint(baseline[old])
    ]
    length(matches) == 1 || continue
    new = only(matches)
    back = [o for o in gone if fingerprint(baseline[o]) == fingerprint(current[new])]
    length(back) == 1 && (pairs[new] = old)
  end
  return pairs
end

"""
    Report

What one `check` found. `ok` is the gate's answer; everything else explains it.
"""
struct Report
  metric::String
  violations::Vector{Violation}
  unparsable::Vector{String}
  unscoped::Vector{String}
  new_files::Vector{String}
  renames::Dict{String,String}
  stale::Vector{String}
end

function ok(report::Report)
  return isempty(report.violations) &&
         isempty(report.unparsable) &&
         isempty(report.unscoped)
end

"""
    ratchet(metric, current, baseline) -> (violations, new_files, renames, stale)

Compare a measurement against a baseline. Knows nothing about what the numbers
mean, which is what keeps every metric on one comparison rule.
"""
function ratchet(metric::Metric, current::Dict{String,Row}, baseline::Dict{String,Row})
  gone = sort([p for p in keys(baseline) if !haskey(current, p)])
  appeared = sort([p for p in keys(current) if !haskey(baseline, p)])
  renames = pair_renames(gone, appeared, current, baseline, row_numbers(metric))

  violations = Violation[]
  for path in sort(collect(keys(current)))
    was = if haskey(baseline, path)
      baseline[path]
    elseif haskey(renames, path)
      baseline[renames[path]]
    else
      nothing
    end
    if was === nothing
      strict_new(metric) || continue
      for key in binding(metric)
        value = get(current[path], key, 0)
        value > 0 && push!(violations, Violation(path, key, 0, value))
      end
      continue
    end
    for key in binding(metric)
      from, to = get(was, key, 0), get(current[path], key, 0)
      to > from && push!(violations, Violation(path, key, from, to))
    end
  end

  new_files = [p for p in appeared if !haskey(renames, p)]
  stale = [p for p in gone if !(p in values(renames))]
  return violations, new_files, renames, stale
end

# --- scope ------------------------------------------------------------------

"""
    tracked_julia_files(root) -> Vector{String}

Every `.jl` file git tracks, repository-relative. Falls back to a walk when
`root` is not a git working tree.
"""
function tracked_julia_files(root::AbstractString)
  if isdir(joinpath(root, ".git"))
    try
      out = read(Cmd(`git ls-files -- "*.jl"`; dir=root), String)
      return sort(filter(!isempty, split(strip(out), '\n')))
    catch
      # fall through to the walk
    end
  end
  found = String[]
  for (dir, _, files) in walkdir(root)
    for file in files
      endswith(file, ".jl") || continue
      rel = relpath(joinpath(dir, file), root)
      startswith(rel, ".git") && continue
      push!(found, replace(rel, '\\' => '/'))
    end
  end
  return sort(found)
end

in_scope(path::AbstractString, scope) = any(p -> startswith(path, p), scope)

"""
    unscoped_files(root, rulings, measured) -> Vector{String}

Tracked `.jl` files that were neither measured nor declared unmeasured.

The assertion is the point. Without it a new top-level directory falls through
silently and is never measured by anything, which is the one failure a ratchet
cannot recover from later.
"""
function unscoped_files(root::AbstractString, rulings::Rulings, measured)
  orphans = String[]
  for path in tracked_julia_files(root)
    path in measured && continue
    in_scope(path, rulings.scope) && continue
    any(p -> startswith(path, p), rulings.unmeasured) && continue
    push!(orphans, path)
  end
  return orphans
end

"""
    parse_failures(root, files) -> Vector{String}

Files that do not parse with errors ON.

CodeComplexity parses with `ignore_errors = true`, so a file with a syntax
error is measured as though it were correct and reports an artificially low
number. A gate that stops measuring without failing is worse than no gate, so
parseability is checked here rather than trusted.
"""
function parse_failures(root::AbstractString, files)
  bad = String[]
  for rel in files
    path = joinpath(root, rel)
    isfile(path) || continue
    try
      JuliaSyntax.parseall(JuliaSyntax.SyntaxNode, read(path, String); ignore_errors=false)
    catch
      push!(bad, rel)
    end
  end
  return bad
end

# --- the verbs --------------------------------------------------------------

"""
    check(metric, root; dir) -> Report

Measure, compare against the baseline, and report. Writes nothing.
"""
function check(
  metric::Metric, root::AbstractString=pwd(); dir::AbstractString=ratchet_dir(root)
)
  rulings = read_rulings(dir)
  current = measure(metric, root)
  baseline, recorded = read_baseline(metric, dir)
  assert_provenance(metric, recorded, root)

  unparsable = parse_failures(root, keys(current))
  unscoped = unscoped_files(root, rulings, keys(current))

  if baseline === nothing
    return Report(
      metric_name(metric),
      Violation[],
      unparsable,
      unscoped,
      sort(collect(keys(current))),
      Dict{String,String}(),
      String[],
    )
  end

  violations, new_files, renames, stale = ratchet(metric, current, baseline)
  return Report(
    metric_name(metric), violations, unparsable, unscoped, new_files, renames, stale
  )
end

"""
    refresh(metric, root; dir, accept_rise) -> Report

Rewrite the baseline from a fresh measurement.

A rise is refused unless `accept_rise` is set, so accepting a worse number is
always a deliberate act with its own flag rather than a side effect of
refreshing.
"""
function refresh(
  metric::Metric,
  root::AbstractString=pwd();
  dir::AbstractString=ratchet_dir(root),
  accept_rise::Bool=false,
)
  report = check(metric, root; dir)
  if !accept_rise && !isempty(report.violations)
    error(
      "refresh refused: " *
      string(length(report.violations)) *
      " binding number(s) rose. Fix them, or pass accept_rise=true to " *
      "record the worse number deliberately.",
    )
  end
  isempty(report.unparsable) || error(
    "refresh refused: these files do not parse, so their numbers are " *
    "meaningless: " *
    join(report.unparsable, ", "),
  )
  write_baseline(metric, dir, measure(metric, root), root)
  return report
end

"""
    ratchet_dir(root) -> String

Where the baselines and `rulings.toml` live. `CODERATCHET_DIR` overrides it.
"""
function ratchet_dir(root::AbstractString)
  return get(ENV, "CODERATCHET_DIR", joinpath(root, "code_ratchet"))
end

function assert_provenance(metric::Metric, recorded::Dict{String,Any}, root::AbstractString)
  isempty(recorded) && return nothing
  expected = provenance(metric, root)
  for (key, value) in expected
    haskey(recorded, key) || continue
    recorded[key] == value || error(
      "baseline provenance mismatch on `$key`: the baseline was written " *
      "against $(repr(recorded[key])) and this run is $(repr(value)). " *
      "Refresh the baseline deliberately rather than comparing across the two.",
    )
  end
  return nothing
end

# --- printing ---------------------------------------------------------------

function Base.show(io::IO, report::Report)
  println(io, "CodeRatchet ", report.metric, ": ", ok(report) ? "PASS" : "FAIL")
  section(label, items) =
    if !isempty(items)
      println(io, "  ", label, " (", length(items), ")")
      for item in items
        println(io, "    ", item)
      end
    end
  section("rose", report.violations)
  section("do not parse", report.unparsable)
  section("measured by nothing", report.unscoped)
  section("new", report.new_files)
  section("gone from the baseline", report.stale)
  if !isempty(report.renames)
    println(io, "  paired as renames (", length(report.renames), ")")
    for (new, old) in sort(collect(report.renames); by=first)
      println(io, "    ", old, " -> ", new)
    end
  end
  return nothing
end

include("complexity.jl")
include("coverage.jl")
include("cli.jl")

end # module CodeRatchet
