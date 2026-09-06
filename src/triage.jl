"""
The ranking half of the gate: what to work on next.

The ratchet stops decay and says nothing about improvement. This is the other
half. It measures the tree, finds what stands above its threshold, ranks it,
drops what the tracker already knows about, and writes a plan of the issues
that should be opened.

**It opens nothing and reads no issue body.** The tracker is read and written
by `gh` in the workflow around it, so every decision lives here, in one place a
person can run and read.
"""

"""
    Candidate

One piece of work worth filing, with a rank comparable across metrics.

`rank` is value over threshold, which is what lets a cyclomatic 20 against a
threshold of 10 outrank a cognitive 20 against a threshold of 15.
"""
struct Candidate
  path::String
  kind::String
  detail::String
  rank::Float64
end

function Base.show(io::IO, c::Candidate)
  return print(
    io, rpad(c.path, 34), " ", c.kind, "  ", c.detail, "  (", round(c.rank; digits=2), "x)"
  )
end

"""
    Issue

One tracker issue, as `gh issue list` reports it. Only the title and the state
are read: the body is the maintainer's, not this job's.
"""
struct Issue
  number::Int
  state::String
  title::String
end

"""
    parse_issues(text) -> Vector{Issue}

The output of

    gh issue list --label code-ratchet --state all \\
      --json number,state,title --template '...'

as `number<TAB>state<TAB>title`, one per line. Unparsable lines are skipped
rather than fatal, because a tracker listing is not this job's contract to
enforce.
"""
function parse_issues(text::AbstractString)
  out = Issue[]
  for line in eachline(IOBuffer(text))
    isempty(strip(line)) && continue
    parts = split(line, '\t')
    length(parts) >= 3 || continue
    number = tryparse(Int, strip(parts[1]))
    number === nothing && continue
    push!(out, Issue(number, uppercase(strip(parts[2])), strip(join(parts[3:end], '\t'))))
  end
  return out
end

"""
    names_path(title, path) -> Bool

Whether an issue title names `path` as a whole token.

A substring test would let a title naming `src/A.jl.orig` suppress `src/A.jl`
for ever, so the test splits on punctuation and compares whole tokens.
"""
function names_path(title::AbstractString, path::AbstractString)
  return any(==(path), split(title, r"[\s`,;()\[\]]+"; keepempty=false))
end

"""
    complexity_candidates(root; dir) -> Vector{Candidate}

Definitions standing above their threshold, one candidate per definition.
"""
function complexity_candidates(root::AbstractString; dir::AbstractString=ratchet_dir(root))
  rulings = read_rulings(dir)
  names = Dict("cyc" => "cyclomatic", "cog" => "cognitive", "arg" => "argcount")
  found = Candidate[]
  for rel in scoped_files(root, rulings.scope)
    for (key, cc) in COMPLEXITY_METRICS
      threshold = get(rulings.thresholds, names[key], 0)
      threshold > 0 || continue
      for fn in measure_file(cc, joinpath(root, rel)).functions
        fn.value > threshold || continue
        push!(
          found,
          Candidate(
            rel,
            "complexity",
            "$(fn.name):$(fn.line) $(names[key])=$(fn.value) > $threshold",
            fn.value / threshold,
          ),
        )
      end
    end
  end
  return found
end

"""
    jet_candidates(root; dir) -> Vector{Candidate}

Files carrying a reviewed JET report, read from the **baseline** rather than by
re-running the analyser.

JET costs minutes, and a ranking job that costs minutes gets run monthly
instead of nightly. The baseline is what the last gate recorded, which is the
number a reader would act on anyway. One reviewed report makes a file a
candidate: inference has no ratio to rank by, so every candidate ranks 1.
"""
function jet_candidates(root::AbstractString; dir::AbstractString=ratchet_dir(root))
  path = joinpath(dir, "jet_baseline.toml")
  isfile(path) || return Candidate[]
  raw = TOML.parsefile(path)
  found = Candidate[]
  for (file, numbers) in get(raw, "files", Dict{String,Any}())
    reviewed = Int(get(numbers, "reviewed", 0))
    reviewed > 0 &&
      push!(found, Candidate(file, "jet", "$reviewed reviewed report(s)", 1.0))
  end
  return found
end

"""
    configured_style_candidates(root; dir) -> Vector{Candidate}

House-rule breaches, or none when the repository does not run the style metric.

Triage ranks across every metric a repository has, and a repository that has
not configured one is not a repository with a broken triage job.
"""
function configured_style_candidates(
  root::AbstractString; dir::AbstractString=ratchet_dir(root)
)
  rulings = read_rulings(dir)
  haskey(rulings.raw, "style") || haskey(rulings.raw, "style_pattern") || return Candidate[]
  return style_candidates(root; dir)
end

"""
    Plan

What the scheduled job decided: the issues to open, and why the rest were not.
"""
struct Plan
  file::Vector{Tuple{String,String}}
  suppressed::Vector{String}
  open_count::Int
  capacity::Int
end

function Base.show(io::IO, plan::Plan)
  println(io, "CodeRatchet triage: ", length(plan.file), " issue(s) to open")
  println(io, "  open queue: ", plan.open_count, " of ", plan.capacity)
  for (title, _) in plan.file
    println(io, "  + ", title)
  end
  if !isempty(plan.suppressed)
    println(io, "  suppressed (", length(plan.suppressed), ")")
    for line in plan.suppressed
      println(io, "    ", line)
    end
  end
  return nothing
end

"""
    triage(root; issues, dir, refile_closed) -> Plan

Decide which candidates to file.

Three rules, in order:

 1. **One issue per file, not per definition.** A file with four breaches is
    one piece of work, ranked by its worst.
 2. **A file the tracker already names is suppressed.** An open issue is
    active work. A closed one means the file has been triaged and the ratchet
    is holding its number, so refiling it is noise; `refile_closed` overrides
    that when a sweep is wanted.
 3. **The cap is on the OPEN count, not on this run.** A per-run cap is blind
    to throughput, so an unworked backlog would grow at a fixed rate. Capping
    the queue makes it self-limiting: if the cap is five and five stand open,
    this run files nothing and the queue paces itself to what actually closes.
"""
function triage(
  root::AbstractString=pwd();
  issues::AbstractString="",
  dir::AbstractString=ratchet_dir(root),
  refile_closed::Bool=false,
)
  rulings = read_rulings(dir)
  cap = Int(get(get(rulings.raw, "scheduled_job", Dict()), "open_queue", 5))
  known = parse_issues(issues)
  open_count = count(i -> i.state == "OPEN", known)

  candidates = vcat(
    complexity_candidates(root; dir),
    configured_style_candidates(root; dir),
    jet_candidates(root; dir),
  )

  worst = Dict{String,Candidate}()
  details = Dict{String,Vector{String}}()
  for c in candidates
    push!(get!(details, c.path, String[]), c.kind * ": " * c.detail)
    held = get(worst, c.path, nothing)
    (held === nothing || c.rank > held.rank) && (worst[c.path] = c)
  end

  suppressed = String[]
  ranked = Candidate[]
  for path in sort(collect(keys(worst)))
    blocking = [
      i for i in known if names_path(i.title, path) && (i.state == "OPEN" || !refile_closed)
    ]
    if isempty(blocking)
      push!(ranked, worst[path])
    else
      i = first(blocking)
      push!(suppressed, "$path: #$(i.number) ($(lowercase(i.state))) already names it")
    end
  end
  sort!(ranked; by=c -> -c.rank)

  capacity = max(0, cap - open_count)
  to_file = Tuple{String,String}[]
  for c in ranked[1:min(capacity, length(ranked))]
    push!(to_file, (issue_title(c), issue_body(c, sort(details[c.path]))))
  end
  for c in ranked[(min(capacity, length(ranked)) + 1):end]
    push!(suppressed, "$(c.path): the open queue is full ($open_count of $cap)")
  end
  return Plan(to_file, suppressed, open_count, cap)
end

issue_title(c::Candidate) = "code-ratchet: reduce $(c.kind) in $(c.path)"

function issue_body(c::Candidate, details::Vector{String})
  io = IOBuffer()
  println(io, "`", c.path, "` stands above its threshold. Filed by the CodeRatchet")
  println(io, "scheduled job, which ranks by value over threshold.")
  println(io)
  println(io, "Worst: ", round(c.rank; digits=2), "x threshold.")
  println(io)
  println(io, "## What stands above")
  println(io)
  for line in details
    println(io, "- ", line)
  end
  println(io)
  println(io, "## What closing this means")
  println(io)
  println(io, "The ratchet already holds this file's numbers where they are, so this issue")
  println(
    io, "is not a regression. It is the improvement half: lower the worst definition,"
  )
  println(io, "then `refresh` so the baseline records the better number.")
  println(io)
  println(
    io, "Closing without a change is a legitimate outcome. It records that the number"
  )
  println(io, "is understood and accepted, and the job will not refile the file.")
  return String(take!(io))
end

"""
    write_plan(plan, out) -> Vector{String}

Write one `NNN-title` and `NNN-body` pair per issue into `out`, for `gh issue
create` to consume. Returns the paths written.
"""
function write_plan(plan::Plan, out::AbstractString)
  mkpath(out)
  written = String[]
  for (i, (title, body)) in enumerate(plan.file)
    stem = joinpath(out, string(i; pad=3))
    write(stem * "-title", title)
    write(stem * "-body", body)
    append!(written, [stem * "-title", stem * "-body"])
  end
  return written
end
