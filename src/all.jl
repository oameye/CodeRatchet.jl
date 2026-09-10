include("coldstart.jl")

"""
Running every gate a repository has configured, in one invocation.

The Makefile of the first repository to adopt this listed five commands, and a
sixth was one refresh away from being forgotten. A list of commands in a
Makefile is a second place the set of gates is written down, and the two drift.
`[metrics].run` in `rulings.toml` is the one place, and everything reads it.

`--only` narrows that set for one run and can never widen it. Narrowing is a
legitimate thing to want: a repository whose JET is already gated absolutely by
another workflow should not pay for JET twice in CI. Widening would be a second
source of truth, so it is refused.
"""

"""
Every metric, cheapest first. The order is the package's, not the
repository's: a repository listing `jet` before `complexity` should still get
the second-long gate first, because a cheap gate that catches the common
mistake ought to fail before one that takes minutes.
"""
const METRIC_ORDER = ("complexity", "style", "docs", "coverage", "boxes", "lsp", "jet")

"""
    configured_metrics(root; dir) -> Vector{Metric}

The metrics `[metrics].run` names, in cost order.

An absent or empty list is an error rather than a run of nothing. A gate that
measures nothing and reports PASS is the worst outcome available, because it
reads as evidence.
"""
function configured_metrics(
  root::AbstractString; dir::AbstractString=ratchet_dir(root), only=String[]
)
  rulings = read_rulings(dir)
  names = String[
    String(n) for n in get(get(rulings.raw, "metrics", Dict()), "run", String[])
  ]
  isempty(names) && error(
    "no metrics configured. Add a [metrics] block to $RULINGS naming `run`, " *
    "for example run = [\"complexity\", \"style\", \"docs\"].",
  )
  unknown = setdiff(names, METRIC_ORDER)
  isempty(unknown) || error(
    "unknown metric(s) in [metrics].run: " *
    join(sort(collect(unknown)), ", ") *
    ". Known metrics: " *
    join(METRIC_ORDER, ", "),
  )

  if !isempty(only)
    stray = setdiff(only, names)
    isempty(stray) || error(
      "--only names metric(s) that [metrics].run does not: " *
      join(sort(collect(stray)), ", ") *
      ". It narrows the configured set; it cannot add to it.",
    )
    names = collect(intersect(names, only))
  end
  # A fresh binding, because the comprehension below is a closure and `names`
  # was reassigned above: capturing a reassigned binding boxes it. Found by
  # this package's own Boxes metric, run on this package.
  selected = names
  return Metric[metric_from(n, root) for n in METRIC_ORDER if n in selected]
end

"""
    Scorecard

Every nonzero binding number a repository has recorded, by file.

Read from the baselines rather than measured, so it costs nothing and answers
the question the gate never does. `check` says what regressed; this says where
the debt actually is.
"""
struct Scorecard
  rows::Vector{Tuple{String,Vector{String}}}
  clean::Int
  metrics::Vector{String}
end

function Base.show(io::IO, card::Scorecard)
  if isempty(card.rows)
    println(io, "Every file is at zero on every binding number.")
    return nothing
  end
  width = maximum(length(first(r)) for r in card.rows)
  println(
    io,
    length(card.rows),
    " file(s) carrying debt, worst first, across ",
    join(card.metrics, ", "),
    ":",
  )
  for (path, notes) in card.rows
    println(io, "  ", rpad(path, width), "  ", join(notes, "  |  "))
  end
  card.clean > 0 && println(io, "  (", card.clean, " file(s) at zero, not listed)")
  return nothing
end

"""
    scorecard(root; dir) -> Scorecard

Rank files by how much recorded debt they carry.

Only keys whose nonzero value means something are listed, so a file's
cyclomatic maximum does not appear beside its actual debt; see [`debt`](@ref).

Ranked on how many metrics flag a file rather than on the numbers themselves,
because a cyclomatic 11 and a JET report are not on one scale and adding them
would invent a total that means nothing. A file two metrics dislike is a better
place to look than a file one metric dislikes loudly.
"""
function scorecard(root::AbstractString=pwd(); dir::AbstractString=ratchet_dir(root))
  metrics = configured_metrics(root; dir)
  per_file = Dict{String,Vector{String}}()
  flagged = Dict{String,Int}()
  seen = Set{String}()
  names = String[]

  for metric in metrics
    baseline, _ = read_baseline(metric, dir)
    baseline === nothing && continue
    push!(names, metric_name(metric))
    for (path, row) in baseline
      push!(seen, path)
      hits = [
        "$key=$(row[key])" for
        key in binding(metric) if get(row, key, 0) > 0 && debt(metric, key)
      ]
      isempty(hits) && continue
      push!(get!(per_file, path, String[]), metric_name(metric) * ": " * join(hits, " "))
      flagged[path] = get(flagged, path, 0) + 1
    end
  end

  paths = sort(collect(keys(per_file)); by=p -> (-flagged[p], p))
  rows = [(p, per_file[p]) for p in paths]
  return Scorecard(rows, length(seen) - length(rows), names)
end
