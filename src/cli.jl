"""
    main(args = ARGS) -> Int

Command-line entry point. Returns the process exit code, so a caller decides
whether to `exit`.

    julia --project=code_ratchet -e 'using CodeRatchet; exit(CodeRatchet.main())' \\
        complexity check

Verbs: `check`, `refresh`, `refresh --accept-rise`, and `candidates` for the
metrics that rank work.
"""
function main(args::AbstractVector{<:AbstractString}=ARGS)
  length(args) >= 2 || return usage()
  metric = metric_from(args[1])
  metric === nothing && return usage("unknown metric $(repr(args[1]))")
  verb = args[2]
  flags = args[3:end]
  root = get(ENV, "CODERATCHET_ROOT", pwd())

  if verb == "check"
    report = check(metric, root)
    print(report)
    extra = metric isa Coverage ? stale_exemptions(root) : String[]
    for line in extra
      println("  stale ruling: ", line)
    end
    return (ok(report) && isempty(extra)) ? 0 : 1
  elseif verb == "refresh"
    accept = "--accept-rise" in flags
    try
      report = refresh(metric, root; accept_rise=accept)
      println("wrote ", baseline_path(metric, ratchet_dir(root)))
      accept &&
        !isempty(report.violations) &&
        println("  accepted ", length(report.violations), " rise(s) deliberately")
      return 0
    catch err
      println(stderr, sprint(showerror, err))
      return 1
    end
  elseif verb == "candidates"
    metric isa Complexity || return usage("candidates is complexity-only")
    found = candidates(root)
    isempty(found) && (println("nothing above threshold"); return 0)
    println(length(found), " definition(s) above threshold, worst first:")
    for definition in found
      println("  ", definition)
    end
    return 0
  end
  return usage("unknown verb $(repr(verb))")
end

metric_from(name::AbstractString) =
  if name == "complexity"
    Complexity()
  elseif name == "coverage"
    Coverage()
  elseif name == "jet"
    jet_metric()
  else
    nothing
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

function usage(problem::Union{Nothing,AbstractString}=nothing)
  problem === nothing || println(stderr, "coderatchet: ", problem)
  println(
    stderr,
    """
usage: coderatchet <metric> <verb> [flags]
  metrics: complexity | coverage | jet
  verbs:   check
           refresh [--accept-rise]
           candidates            (complexity only)
  env:     CODERATCHET_ROOT, CODERATCHET_DIR, COVERAGE_LCOV""",
  )
  return 2
end
