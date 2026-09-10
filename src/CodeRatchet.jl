"""
    CodeRatchet

A per-file ratchet for Julia code-quality metrics.

The ratchet is the whole idea: a number only has to stop getting worse. That is
what makes it adoptable on a codebase where the absolute bar is out of reach
today, which an absolute gate never is.

One deep module, three thin adapters. [`ratchet`](@ref) compares a measurement
against a baseline and knows nothing about complexity, coverage or inference; a
[`Metric`](@ref) says how to produce rows and which of their numbers bind.

Adapted from the `code_health/` directory of PortfolioOptimisers.jl by Daniel
Celis Garza (MIT). See LICENSE.
"""
module CodeRatchet

using JuliaSyntax: JuliaSyntax
using TOML: TOML

export Boxes, Complexity, Coverage, Docstrings, Lsp, Style, check, refresh

"""
    oneof(x, options) -> Bool

Whether `x` is one of `options`, as a `Bool` and not a `Union{Bool,Missing}`.

`in` and `any` are three-valued: they return `missing` when an element's
comparison does, so inference types them `Union{Bool,Missing}` even where the
elements are symbols and no comparison can. JETLS reported six
`non-boolean Missing found in boolean context` warnings on exactly that, each
one a `missing` that would reach an `&&`. The assertion says it cannot happen
and fails loudly rather than silently if it ever does.
"""
oneof(x, options) = (x in options)::Bool

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

An implementation provides `metric_name`, `binding`, `row_numbers`, `measure`
and `provenance`. Nothing else in this package knows what the numbers mean.
"""
abstract type Metric end

"""
    metric_name(metric) -> String

Baseline filename stem, so `Complexity()` writes `complexity_baseline.toml`.
"""
function metric_name end

"""
    baseline_stem(metric) -> String

The baseline's filename, with the interface contract asserted rather than
assumed.

`metric_name` is a bare interface function, so inference gives it `Any` for an
abstract `Metric`, and `Any * "_baseline.toml"` admits `Missing` and `Regex`:
JET reported two `joinpath(::AbstractString, ::Missing)` errors on exactly
that. The assertion makes the type concrete and turns a metric returning the
wrong thing into a named failure at the boundary rather than a method error
deeper in.
"""
baseline_stem(metric::Metric) = (metric_name(metric)::String) * "_baseline.toml"

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
    measure(metric, root; dir) -> Dict{String,Row}

Measure `root`, keyed by repository-relative path with `/` separators.

`dir` is where `rulings.toml` lives, and it is a parameter rather than
recomputed from `root` because it was recomputed before and that was a bug:
`check` read its rulings from the `dir` it was given while `measure` read
theirs from `ratchet_dir(root)`, so a non-default directory took its scope from
one file and its baselines from another. `CODERATCHET_DIR` made the two agree
in practice, which is why nothing caught it until JETLS pointed at a `dir`
argument that went unused two functions away.
"""
function measure end

"""
    provenance(metric, root) -> Dict{String,Any}

What the run depended on. Written into the baseline and asserted on read, so a
baseline is never compared against a run that measured a different thing.

`commit` is written but never compared: the baseline is always older than the
tree, so it is context for a reader.
"""
provenance(::Metric, ::AbstractString) = Dict{String,Any}()

"""
    metric_schema(metric) -> Int

Version of the metric's measurement semantics. Increment it when the same
configuration would produce numbers with a different meaning.
"""
metric_schema(::Metric) = 1

"""
    measurement_provenance(metric, root) -> Dict{String,Any}

Complete semantic identity of one measurement. Every field except `commit`
binds: a baseline is comparable only when the semantic key set and values agree.
"""
function measurement_provenance(metric::Metric, root::AbstractString)
  result = copy(provenance(metric, root))
  result["schema"] = metric_schema(metric)
  result["binding"] = collect(binding(metric))
  result["direction"] = [string(direction(metric, key)) for key in binding(metric)]
  return result
end

"""
    entry_failures(metric, root, paths, rows) -> Vector{String}

Extra failures a metric demands of files entering with no baseline row.

Empty by default, which lets a new file enter at whatever it measures. That is
right when the metric has no natural zero. Coverage overrides it: an added file
enters fully covered or exempted, because there the zero is meaningful.
"""
entry_failures(::Metric, ::AbstractString, ::Any, ::Any) = String[]

"""
    direction(metric, key) -> Symbol

Which way `key` is allowed to move: `:down` (the default) or `:up`.

Nearly every quality number is one whose complement is also a number, and the
one with a reachable zero is the one to bind: misses rather than percentage,
undocumented names rather than documented ones. Those all bind `:down`, which
is why that is the default.

`:up` is for a quantity with no complement to count. "How many tests this file
asserts" is the clearest case: there is no such thing as a test not written, so
the only gate available is that the number must not fall. Deleting tests to
turn CI green is a real failure mode, and it is invisible to every `:down`
number in this package.
"""
direction(::Metric, ::AbstractString) = :down

"""
    debt(metric, key) -> Bool

Whether a nonzero value of `key` means the file owes work.

Almost every number here counts something that should not be there, so the
default is `true`. A **maximum** is the exception: every non-empty file has a
cyclomatic maximum of at least one, so a nonzero `cyc` is not evidence of
anything and listing it as debt buries the numbers that are.

Distinct from `binding`, which asks whether a key can fail the gate. A maximum
both binds and is not debt: it must not rise, and its current value is not a
complaint.
"""
debt(::Metric, ::AbstractString) = true

"""
    dismissal_section(metric) -> String

The `rulings.toml` section holding this metric's dismissals, or `""` when it
has none.

Only a metric whose findings can be *wrong* gets dismissals. A complexity
number is never wrong, so there is nothing to dismiss and the remedy must not
offer the route; an inference report can be a false positive, so it must.
"""
dismissal_section(::Metric) = ""

"""
    ruling_failures(metric, root) -> Vector{String}

Failures in the hand-written rulings themselves, checked on every run.

A ruling is a claim about specific code. When the code moves under it the claim
expires, and an expired ruling quietly widens the gate.
"""
ruling_failures(::Metric, ::AbstractString) = String[]

# --- the rulings file ------------------------------------------------------

const RULINGS = "rulings.toml"

"""
    Rulings

The hand-written half of the gate. Nothing here is measured, and no verb in
this package ever rewrites this file. That split is the point: no human
paragraph shares a file that a refresh overwrites.
"""
struct Rulings
  thresholds::Dict{String,Int}
  scope::Vector{String}
  unmeasured::Vector{String}
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
  return Rulings(thresholds, scope, unmeasured, raw)
end

# --- the baseline file -----------------------------------------------------

function baseline_path(metric::Metric, dir::AbstractString)
  return joinpath(dir, baseline_stem(metric))
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

"""
    render_baseline(metric, rows, root) -> String

The baseline file as text.

The lines are printed rather than handed to `TOML.print`, which emits keys in
hash order and would make every regeneration a whole-file diff.
"""
function render_baseline(metric::Metric, rows::Dict{String,Row}, root::AbstractString)
  io = IOBuffer()
  println(
    io, "# Generated by CodeRatchet.jl. Every number here is measured, so this file is"
  )
  println(io, "# rewritten wholesale by `refresh` and must not be hand-edited. The human")
  println(io, "# judgements live in $RULINGS beside it.")
  println(io)
  println(io, "[provenance]")
  for (key, value) in sort(collect(measurement_provenance(metric, root)); by=first)
    println(io, key, " = ", tomlvalue(value))
  end
  for file in sort(collect(keys(rows)))
    println(io)
    println(io, "[files.", repr(file), "]")
    row = rows[file]
    for key in row_numbers(metric)
      haskey(row.numbers, key) && println(io, key, " = ", row.numbers[key])
    end
  end
  return String(take!(io))
end

tomlvalue(v::AbstractString) = repr(String(v))
tomlvalue(v::Integer) = string(v)
tomlvalue(v::Bool) = v ? "true" : "false"
tomlvalue(v::AbstractVector) = "[" * join(map(tomlvalue, v), ", ") * "]"

# --- the ratchet ------------------------------------------------------------

"""
    Violation

One binding number that moved the wrong way. Carries both values, because a
violation the
reader cannot size is a violation they cannot act on.
"""
struct Violation
  path::String
  key::String
  from::Int
  to::Int
end

"""
    moved(v) -> String

"rose" or "fell", read off the numbers.

Taking the word from the values rather than from the metric's direction keeps
the two from ever disagreeing: a violation that says it rose is one whose
second number is larger, whichever direction made it a violation.
"""
moved(v::Violation) = v.to > v.from ? "rose" : "fell"

function Base.show(io::IO, v::Violation)
  return print(io, v.path, ": ", v.key, " ", moved(v), " ", v.from, " -> ", v.to)
end

"""
    set_differences(expected, recorded) -> (missing_rows, dead_rows)

`missing_rows` are in-scope files the baseline does not name, and `dead_rows`
are rows that name nothing.

Both are failures, and that is the point. A file with no row would otherwise
pass the gate at any number at all until some later refresh baked it in
silently; demanding the row puts the number in the diff of the change that
introduced it.
"""
function set_differences(expected, recorded)
  wanted, held = Set(expected), Set(recorded)
  return sort!(collect(setdiff(wanted, held))), sort!(collect(setdiff(held, wanted)))
end

"""
    pair_renames(dead, added, baseline, current, keys) -> Dict{String,String}

Pair a file that vanished with one that appeared when every number matches.

Pairing on the full number set rather than the binding subset is deliberate:
two unrelated files often share a worst definition, and pairing them would
carry the wrong history forward. The pairing is safe by arithmetic: when the
numbers are equal it does not matter which dead row takes which new path, so
the multiset of recorded numbers cannot rise.
"""
function pair_renames(dead, added, baseline, current, keys)
  fingerprint(row) = Int[get(row, k, -1) for k in keys]
  pairs = Dict{String,String}()
  available = collect(added)
  for old in dead
    index = findfirst(
      new -> fingerprint(current[new]) == fingerprint(baseline[old]), available
    )
    index === nothing && continue
    pairs[available[index]] = old
    deleteat!(available, index)
  end
  return pairs
end

"""
    Report

What one `check` found. `ok` is the gate's answer; everything else explains it.

`held` is what the measurement still carries, per debt key, summed over files.
It has nothing to do with whether the gate passed, and that is exactly why it
is here: see [`held_summary`](@ref).
"""
struct Report
  metric::String
  violations::Vector{Violation}
  unparsable::Vector{String}
  unscoped::Vector{String}
  missing_rows::Vector{String}
  dead_rows::Vector{String}
  entry::Vector{String}
  rulings::Vector{String}
  renames::Dict{String,String}
  bootstrap::Bool
  held::Dict{String,Int}
end

function ok(report::Report)
  return isempty(report.violations) &&
         isempty(report.unparsable) &&
         isempty(report.unscoped) &&
         isempty(report.missing_rows) &&
         isempty(report.dead_rows) &&
         isempty(report.entry) &&
         isempty(report.rulings)
end

"""
    held_totals(metric, rows) -> Dict{String,Int}

Per-key totals of the debt a measurement carries, zeros omitted.

Only [`debt`](@ref) keys are summed, so a file's cyclomatic maximum does not
appear: every non-empty file has one, and a total over maxima means nothing.
"""
function held_totals(metric::Metric, rows::Dict{String,Row})
  totals = Dict{String,Int}()
  for key in binding(metric)
    debt(metric, key) || continue
    n = sum((get(row, key, 0) for row in values(rows)); init=0)
    n > 0 && (totals[key] = n)
  end
  return totals
end

"""
    held_summary(report) -> String

What the gate is holding, said out loud beside the verdict.

A ratchet's `PASS` means *did not rise*, and the word reads as *clean*. Writing
this package I misread my own output three times in one sitting: `boxes: PASS`
while the baseline held three boxes, `jet: PASS` while twelve reports stood.
Each time the numbers were already in hand and the gate declined to mention
them. A gate that can be mistaken for a clean bill of health is worse than a
loud one, so the verdict now always carries the debt behind it.
"""
function held_summary(report::Report)
  isempty(report.held) && return "clean"
  return "holding " * join(
    ("$key=$(report.held[key])" for key in sort(collect(keys(report.held)))), ", "
  )
end

"""
    ratchet(metric, current, baseline) -> (violations, missing_rows, dead_rows, renames)

Compare a measurement against a baseline. Knows nothing about what the numbers
mean, which is what keeps every metric on one comparison rule.
"""
function ratchet(metric::Metric, current::Dict{String,Row}, baseline::Dict{String,Row})
  missing_rows, dead_rows = set_differences(keys(current), keys(baseline))
  renames = pair_renames(dead_rows, missing_rows, baseline, current, row_numbers(metric))

  violations = Violation[]
  for path in sort(collect(keys(current)))
    was = if haskey(baseline, path)
      baseline[path]
    elseif haskey(renames, path)
      baseline[renames[path]]
    else
      nothing
    end
    was === nothing && continue
    for key in binding(metric)
      from, to = get(was, key, 0), get(current[path], key, 0)
      moved_wrong = direction(metric, key) === :up ? to < from : to > from
      moved_wrong && push!(violations, Violation(path, key, from, to))
    end
  end

  unpaired_new = [p for p in missing_rows if !haskey(renames, p)]
  unpaired_dead = [p for p in dead_rows if !(p in values(renames))]
  return violations, unpaired_new, unpaired_dead, renames
end

# --- scope ------------------------------------------------------------------

"""
    tracked_julia_files(root) -> Vector{String}

Every `.jl` file git tracks, repository-relative.

`git ls-files` rather than a directory walk, because a walk ignores
`.gitignore` and picks up untracked scratch files, which would then have to be
declared unmeasured to keep the gate green. `-z` because a path may contain a
newline.
"""
function tracked_julia_files(root::AbstractString)
  isdir(joinpath(root, ".git")) || error(
    "$root is not a git working tree. CodeRatchet takes its file list from " *
    "`git ls-files`, because a directory walk would pick up untracked files.",
  )
  out = read(Cmd(`git ls-files -z -- "*.jl"`; dir=root), String)
  return sort!(filter!(!isempty, split(out, '\0')))
end

"""
    short_commit(root) -> String

The commit a baseline was taken at, for a reader. Never compared.
"""
function short_commit(root::AbstractString)
  try
    # git's stderr is swallowed rather than shown: outside a working tree this
    # falls back to "unknown" on purpose, and a `fatal:` line in the log would
    # read as a failure when nothing failed.
    return strip(
      read(pipeline(Cmd(`git rev-parse --short HEAD`; dir=root); stderr=devnull), String)
    )
  catch
    return "unknown"
  end
end

in_scope(path::AbstractString, scope) = any(p -> startswith(path, p), scope)

"""
    scoped_files(root, scope) -> Vector{String}

Tracked `.jl` files inside the measured scope, repository-relative.
"""
function scoped_files(root::AbstractString, scope)
  return [p for p in tracked_julia_files(root) if in_scope(p, scope)]
end

"""
    unscoped_files(root, rulings) -> Vector{String}

Tracked `.jl` files that are neither in scope nor declared unmeasured.

The assertion is the point. Without it a new top-level directory falls through
silently and is never measured by anything, which is the one failure a ratchet
cannot recover from later.
"""
function unscoped_files(root::AbstractString, rulings::Rulings)
  orphans = String[]
  for path in tracked_julia_files(root)
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
  return sort!(bad)
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
  current = measure(metric, root; dir)
  baseline, recorded = read_baseline(metric, dir)

  unparsable = parse_failures(root, keys(current))
  unscoped = unscoped_files(root, rulings)
  ruling_bad = ruling_failures(metric, root)

  # No baseline at all is the bootstrap case, not a wall of failures.
  if baseline === nothing || isempty(baseline)
    return Report(
      metric_name(metric),
      Violation[],
      unparsable,
      unscoped,
      String[],
      String[],
      String[],
      ruling_bad,
      Dict{String,String}(),
      true,
      held_totals(metric, current),
    )
  end

  provenance_bad = provenance_failures(metric, recorded, root)
  isempty(provenance_bad) || return Report(
    metric_name(metric),
    Violation[],
    unparsable,
    unscoped,
    String[],
    String[],
    String[],
    vcat(ruling_bad, provenance_bad),
    Dict{String,String}(),
    false,
    held_totals(metric, current),
  )

  violations, new_files, dead, renames = ratchet(metric, current, baseline)
  entry = entry_failures(metric, root, new_files, current)
  return Report(
    metric_name(metric),
    violations,
    unparsable,
    unscoped,
    new_files,
    dead,
    entry,
    ruling_bad,
    renames,
    false,
    held_totals(metric, current),
  )
end

"""
    refresh(metric, root; dir, accept_change) -> Report

Rewrite the baseline from a fresh measurement.

A bare refresh only ever lowers a number, so its diff is always an improvement
and it is safe to run without thought. Recording a rise is a second, named act.
"""
function refresh(
  metric::Metric,
  root::AbstractString=pwd();
  dir::AbstractString=ratchet_dir(root),
  accept_change::Bool=false,
)
  report = check(metric, root; dir)
  human_rulings = ruling_failures(metric, root)
  isempty(human_rulings) || error(
    "refresh refused: fix invalid rulings before changing a generated baseline: " *
    join(human_rulings, "; "),
  )

  baseline, recorded = read_baseline(metric, dir)
  provenance_bad = if baseline === nothing || isempty(baseline)
    String[]
  else
    provenance_failures(metric, recorded, root)
  end
  if !accept_change && !isempty(provenance_bad)
    error(
      "refresh refused: this baseline was measured under incompatible provenance. " *
      "Review the semantic/tool change, then re-run with --accept-change to migrate it deliberately. " *
      join(provenance_bad, "; "),
    )
  end
  if !accept_change && !isempty(report.violations)
    error(refuse_rise(metric_name(metric), report.violations))
  end
  isempty(report.unparsable) || error(
    "refresh refused: these files do not parse, so their numbers are meaningless: " *
    join(report.unparsable, ", "),
  )
  write(
    baseline_path(metric, dir), render_baseline(metric, measure(metric, root; dir), root)
  )
  return report
end

"""
    ratchet_dir(root) -> String

Where the baselines and `rulings.toml` live. `CODERATCHET_DIR` overrides it.
"""
function ratchet_dir(root::AbstractString)
  return get(ENV, "CODERATCHET_DIR", joinpath(root, "code_ratchet"))
end

"""
    provenance_failures(metric, recorded, root) -> Vector{String}

Every provenance field except `commit` must match. The baseline is always older
than the tree, so the commit is context for a reader and never binds.

A mismatch is its own failure rather than a violation: the numbers came from a
different tool, so comparing them at all would be meaningless.
"""
function provenance_failures(
  metric::Metric, recorded::Dict{String,Any}, root::AbstractString
)
  expected = measurement_provenance(metric, root)
  comparable_keys(table) = Set(k for k in keys(table) if k != "commit")
  expected_keys = comparable_keys(expected)
  recorded_keys = comparable_keys(recorded)
  bad = String[]

  for key in sort!(collect(setdiff(expected_keys, recorded_keys)))
    push!(
      bad,
      "provenance missing from the baseline: $key is now required as " *
      "$(repr(expected[key])). Refresh the baseline in the same commit that moved the tool.",
    )
  end
  for key in sort!(collect(setdiff(recorded_keys, expected_keys)))
    push!(
      bad,
      "stale provenance in the baseline: $key = $(repr(recorded[key])) is no longer " *
      "part of this metric. Refresh the baseline in the same commit that moved the tool.",
    )
  end
  for key in sort!(collect(intersect(expected_keys, recorded_keys)))
    recorded[key] == expected[key] && continue
    push!(
      bad,
      "provenance moved under the baseline: $key was $(repr(recorded[key])), " *
      "now $(repr(expected[key])). Refresh the baseline in the same commit that moved the tool.",
    )
  end
  return bad
end

"""
    refuse_rise(kind, violations) -> String

The message a refused refresh prints.

"change" rather than "rise", because a number binding `:up` is a violation when
it falls, and a message that says "rise" about a fall reads as a different bug.
"""
function refuse_rise(kind::AbstractString, violations::Vector{Violation})
  io = IOBuffer()
  for v in violations
    println(io, "ERROR: ", v)
  end
  print(
    io, "Re-run with --accept-change to record ", length(violations), " change(s) in $kind."
  )
  return String(take!(io))
end

"""
    routes(; dismissal, moves) -> String

The remedy, in its ordered routes.

Order matters. A refresh is the last route, not the first, and naming it first
would make it the reflex. The dismissal route appears only for a metric that
has one, named by `dismissal_section`.

`moves` is the direction the first route asks for. A metric whose numbers all
run one way names that way; one carrying both says neither, because "lower it"
is wrong advice for half of them.
"""
function routes(; dismissal::AbstractString, moves::Symbol=:down)
  io = IOBuffer()
  println(io, "A refresh is not the fix. Take one of these routes, in order.")
  first_route = if moves === :down
    "Lower the number."
  elseif moves === :up
    "Raise the number."
  else
    "Move the number back."
  end
  println(io, "  1. ", first_route)
  n = 2
  if !isempty(dismissal)
    println(
      io, "  2. Add a [[$dismissal]] to $RULINGS, with the reason it is not a defect."
    )
    n = 3
  end
  println(io, "  $n. Record the change deliberately, with `refresh --accept-change`.")
  print(io, "     In CI, take the baseline from this run's refresh artifact and commit it.")
  return String(take!(io))
end

"""
    advised_move(metric) -> Symbol

The direction to name in the remedy: `:down`, `:up`, or `:mixed` when the
metric's binding numbers do not agree.
"""
function advised_move(metric::Metric)
  ways = unique(direction(metric, key) for key in binding(metric))
  return length(ways) == 1 ? only(ways) : :mixed
end

# --- reporting --------------------------------------------------------------

is_ci() = haskey(ENV, "GITHUB_ACTIONS")

"""
    annotate(path, message)

One `::error` annotation per offending file, so a red gate lands on the diff in
a pull request rather than only in a log. Outside CI the same text is printed
plainly.
"""
function annotate(path::AbstractString, message::AbstractString)
  if is_ci()
    println("::error file=", path, "::", message)
  else
    println("  ", path, ": ", message)
  end
  return nothing
end

"""
    step_summary(text)

Append to the GitHub step summary, when there is one.
"""
function step_summary(text::AbstractString)
  path = get(ENV, "GITHUB_STEP_SUMMARY", "")
  isempty(path) || open(io -> println(io, text), path, "a")
  return nothing
end

"""
    rise_table(violations) -> String

The markdown table for the step summary. It names every offending file,
including one whose number moved for a reason absent from the diff.
"""
function rise_table(violations::Vector{Violation})
  io = IOBuffer()
  println(io, "| file | metric | baseline | now | moved |")
  println(io, "| --- | --- | --- | --- | --- |")
  for v in violations
    println(
      io, "| ", v.path, " | ", v.key, " | ", v.from, " | ", v.to, " | ", moved(v), " |"
    )
  end
  return String(take!(io))
end

const ARTIFACT_DIR = "_refresh"

"""
    write_artifact(metric, root, dir) -> String

Write the baseline as `refresh --accept-change` would write it, for upload from a
failing CI run.

The point is that a contributor fixes a red gate by downloading a file and
committing it at its recorded path. No Julia, no local environment, no reading
of this package.
"""
function write_artifact(metric::Metric, root::AbstractString, dir::AbstractString)
  out = joinpath(dir, ARTIFACT_DIR)
  mkpath(out)
  path = joinpath(out, baseline_stem(metric))
  write(path, render_baseline(metric, measure(metric, root), root))
  return path
end

function Base.show(io::IO, report::Report)
  println(
    io,
    "CodeRatchet ",
    report.metric,
    ": ",
    ok(report) ? "PASS" : "FAIL",
    ", ",
    held_summary(report),
  )
  report.bootstrap && println(io, "  no baseline yet; `refresh` to take one")
  section(label, items) =
    if !isempty(items)
      println(io, "  ", label, " (", length(items), ")")
      for item in items
        println(io, "    ", item)
      end
    end
  section("moved", report.violations)
  section("do not parse", report.unparsable)
  section("measured by nothing", report.unscoped)
  section("no baseline row", report.missing_rows)
  section("row names nothing", report.dead_rows)
  section("entering unclean", report.entry)
  section("stale rulings", report.rulings)
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
include("style.jl")
include("boxes.jl")
include("docs.jl")
include("lsp.jl")
include("triage.jl")
include("cli.jl")
include("all.jl")
include("init.jl")

end # module CodeRatchet
