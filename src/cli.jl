"""
    main(args = ARGS) -> Int

Command-line entry point. Returns the process exit code, so a caller decides
whether to `exit`.

    julia --project=code_ratchet \\
      -e 'using CodeRatchet; exit(CodeRatchet.main())' complexity check

In CI a failing check emits one `::error` annotation per offending file, writes
a rise table to the step summary, and stages a **refresh artifact**: the
baseline as `refresh --accept-change` would have written it. A contributor fixes
a red gate by downloading that file and committing it at its recorded path,
with no Julia and no local environment.
"""
function main(args::AbstractVector{<:AbstractString}=ARGS)
  isempty(args) && return usage()
  root = get(ENV, "CODERATCHET_ROOT", pwd())
  # `init` and `all` are not about one metric, so they are matched before the
  # first argument is read as a metric name.
  args[1] == "init" && return do_init(root, args[2:end])
  args[1] == "all" && return do_group(root, args[2:end])
  length(args) >= 2 && return dispatch(args)
  return usage()
end

"""
    do_init(root, flags) -> Int

Scaffold `code_ratchet/`, then say what to run next. It writes configuration
and takes no baselines: three of the metrics need an environment that does not
exist until the file this command just wrote has been instantiated.
"""
function do_init(root::AbstractString, flags)
  dir = ratchet_dir(root)
  written = try
    initialise(root; dir, force=("--force" in flags))
  catch err
    println(stderr, sprint(showerror, err))
    return 1
  end
  if isempty(written)
    println("nothing written; pass --force to overwrite what is already there")
  else
    foreach(p -> println("wrote ", p), written)
  end
  println()
  println("Next, from the repository root:")
  println("  julia --project=$(relpath(dir, root)) -e 'using Pkg; Pkg.instantiate()'")
  println(
    "  julia --project=$(relpath(dir, root)) ",
    "-e 'using CodeRatchet; exit(CodeRatchet.main())' all refresh",
  )
  println()
  println("That takes the first baselines. Commit them with $(RULINGS).")
  return 0
end

"""
    do_group(root, args) -> Int

Run one verb across every metric `[metrics].run` names.

Each gate reports itself, so a failure explains itself where it happened. The
line at the end exists because five PASS lines and one FAIL scroll past, and
the answer to "did it pass" should not need re-reading.
"""
function do_group(root::AbstractString, args)
  dir = ratchet_dir(root)
  verb = isempty(args) ? "check" : args[1]
  only = String[]
  for (i, flag) in enumerate(args)
    flag == "--only" && i < length(args) && (only = split(args[i + 1], ","))
  end
  metrics = try
    configured_metrics(root; dir, only)
  catch err
    println(stderr, sprint(showerror, err))
    return 1
  end

  verb == "scorecard" && (print(scorecard(root; dir)); return 0)
  verb in ("check", "refresh") ||
    return usage("`all` takes check, refresh or scorecard, not $(repr(verb))")

  failed = String[]
  for metric in metrics
    println("── ", metric_name(metric), " ", "─"^max(0, 60 - length(metric_name(metric))))
    code = if verb == "check"
      do_check(metric, root, dir)
    else
      do_refresh(metric, root, dir, any(f -> f in ("--accept-change", "--accept-rise"), args))
    end
    code == 0 || push!(failed, metric_name(metric))
  end

  println()
  if isempty(failed)
    println("CodeRatchet: all ", length(metrics), " gate(s) passed.")
    return 0
  end
  println(
    "CodeRatchet: ",
    length(failed),
    " of ",
    length(metrics),
    " gate(s) failed (",
    join(failed, ", "),
    ").",
  )
  return 1
end

function dispatch(args)
  root = get(ENV, "CODERATCHET_ROOT", pwd())
  dir = ratchet_dir(root)
  metric = metric_from(args[1], root; dir)
  metric === nothing && return usage("unknown metric $(repr(args[1]))")
  verb, flags = args[2], args[3:end]

  verb == "check" && return do_check(metric, root, dir)
  verb == "refresh" && return do_refresh(
    metric, root, dir, any(f -> f in ("--accept-change", "--accept-rise"), flags)
  )
  verb == "candidates" && return do_candidates(metric, root, dir)
  verb == "triage" && return do_triage(metric, root, dir, flags)
  verb == "terminal" && return do_terminal(metric, root, dir)
  verb == "methods" && return do_methods(metric, root, dir)
  verb == "report" && return do_report(metric, root, dir)
  verb == "undocumented" && return do_undocumented(metric, root, dir)
  return usage("unknown verb $(repr(verb))")
end

function check_summary(report::Report)
  isempty(report.violations) && isempty(report.finding_violations) && return nothing
  parts = String["### CodeRatchet $(report.metric)"]
  isempty(report.violations) || push!(parts, rise_table(report.violations))
  isempty(report.finding_violations) ||
    push!(parts, finding_table(report.finding_violations))
  return join(parts, "\n\n")
end

function do_check(metric::Metric, root::AbstractString, dir::AbstractString)
  report = check(metric, root; dir)
  print(report)
  ok(report) && return 0

  for v in report.violations
    annotate(
      v.path,
      "$(v.key) $(moved(v)) $(v.from) -> $(v.to); the ratchet holds it at $(v.from).",
    )
  end
  for v in report.finding_violations
    annotate(v.path, "new finding $(repr(v.identity)); multiplicity $(v.from) -> $(v.to).")
  end
  for path in report.unparsable
    annotate(path, "does not parse, so its numbers are meaningless.")
  end
  for path in report.unscoped
    annotate(
      path, "is measured by nothing. Put it in [scope] or name an [[unmeasured_path]]."
    )
  end
  for path in report.missing_rows
    annotate(path, "has no baseline row. Refresh in the same change that added it.")
  end

  summary = check_summary(report)
  summary === nothing || step_summary(summary)
  println()
  println(routes(; dismissal=dismissal_section(metric), moves=advised_move(metric)))

  # A provenance mismatch means the numbers came from a different tool, so an
  # artifact built from them would be the wrong file to commit.
  if isempty(report.rulings)
    try
      println("\nRefresh artifact: ", write_artifact(metric, root, dir))
    catch err
      println(stderr, "\nNo refresh artifact: ", sprint(showerror, err))
    end
  else
    println("\nNo refresh artifact: fix the rulings above first.")
  end
  return 1
end

function do_refresh(metric::Metric, root::AbstractString, dir::AbstractString, accept::Bool)
  try
    report = refresh(metric, root; dir, accept_change=accept)
    println("wrote ", baseline_path(metric, dir))
    n = length(report.violations) + length(report.finding_violations)
    accept && n > 0 && println("  recorded ", n, " change(s) deliberately")
    return 0
  catch err
    println(stderr, sprint(showerror, err))
    println(stderr)
    println(
      stderr, routes(; dismissal=dismissal_section(metric), moves=advised_move(metric))
    )
    return 1
  end
end

function do_candidates(metric::Metric, root::AbstractString, dir::AbstractString)
  metric isa Complexity || return usage("candidates is complexity-only")
  found = sort(complexity_candidates(root; dir); by=c -> -c.rank)
  isempty(found) && (println("nothing above threshold"); return 0)
  println(length(found), " definition(s) above threshold, worst first:")
  for c in found
    println("  ", c)
  end
  return 0
end

function do_triage(metric::Metric, root::AbstractString, dir::AbstractString, flags)
  metric isa Complexity ||
    return usage("triage ranks across metrics; call it on `complexity`")
  issues = ""
  for (i, flag) in enumerate(flags)
    flag == "--issues" && i < length(flags) && (issues = read(flags[i + 1], String))
  end
  plan = triage(root; issues, dir, refile_closed=("--refile-closed" in flags))
  print(plan)
  out = joinpath(dir, "_triage")
  if !isempty(plan.file)
    write_plan(plan, out)
    println("\nwrote the plan to ", out)
  end
  return 0
end

function do_terminal(metric::Metric, root::AbstractString, dir::AbstractString)
  metric isa Coverage || return usage("terminal is coverage-only")
  short = terminal(root; dir)
  isempty(short) && (println("every file in scope is fully covered"); return 0)
  println(length(short), " file(s) short of zero misses, worst first:")
  for line in short
    println("  ", line)
  end
  return 0
end

function do_methods(metric::Metric, root::AbstractString, dir::AbstractString)
  metric isa Boxes || return usage("methods is boxes-only")
  found = boxed_methods(root; dir)
  isempty(found) && (println("no method boxes a capture"); return 0)
  println(length(found), " boxed capture(s):")
  for line in found
    println("  ", line)
  end
  return 0
end

function do_report(metric::Metric, root::AbstractString, dir::AbstractString)
  metric isa Lsp || return usage("report is lsp-only")
  found = lsp_report(root; dir)
  isempty(found) && (println("no undismissed diagnostics"); return 0)
  println(length(found), " undismissed diagnostic(s):")
  for line in found
    println("  ", line)
  end
  return 0
end

function do_undocumented(metric::Metric, root::AbstractString, dir::AbstractString)
  metric isa Docstrings || return usage("undocumented is docs-only")
  owed = undocumented(root; dir)
  isempty(owed) && (println("every public name has a docstring"); return 0)
  println(length(owed), " public name(s) with no docstring:")
  for line in owed
    println("  ", line)
  end
  return 0
end

function metric_from(
  name::AbstractString, root::AbstractString; dir::AbstractString=ratchet_dir(root)
)
  return if name == "complexity"
    Complexity()
  elseif name == "coverage"
    Coverage()
  elseif name == "style"
    Style(root; dir)
  elseif name == "docs"
    Docstrings()
  elseif name == "boxes"
    Boxes()
  elseif name == "lsp"
    Lsp()
  elseif name == "jet"
    jet_metric()
  else
    nothing
  end
end

"""
    jet_metric()

The JET adapter, which lives in an extension because JET must load the package
under measurement and costs minutes where the other two cost seconds.
"""
function jet_metric()
  ext = Base.get_extension(@__MODULE__, :CodeRatchetJETExt)
  ext === nothing && error(
    "the JET metric needs JET loaded. Add JET to your code_ratchet environment " *
    "and `using JET` before calling CodeRatchet.",
  )
  return ext.Inference()
end

usage(problem::AbstractString) = (println(stderr, "coderatchet: ", problem); usage())

function usage()
  println(
    stderr,
    """
usage: coderatchet <metric> <verb> [flags]
         coderatchet init [--force]
         coderatchet all [check | refresh | scorecard] [--only a,b]
  metrics: complexity | coverage | style | docs | boxes | lsp | jet
  verbs:   check
           refresh [--accept-change]
           candidates                        (complexity only)
           triage [--issues FILE] [--refile-closed]
           terminal                          (coverage only)
           methods                           (boxes only)
           report                            (lsp only)
           undocumented                      (docs only)
  env:     CODERATCHET_ROOT, CODERATCHET_DIR, COVERAGE_LCOV""",
  )
  return 2
end
