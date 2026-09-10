export coldstart_compare, coldstart_main

function _coldstart_usage(problem::AbstractString="")
  isempty(problem) || println(stderr, "coderatchet coldstart: ", problem)
  println(
    stderr,
    "usage: coderatchet coldstart compare --base PATH [--head PATH] " *
    "[--ratchet-dir PATH] [--output PATH]",
  )
  return 2
end

function _coldstart_flag_value(args, index, flag)
  index < length(args) || error("$flag needs a value")
  return String(args[index + 1])
end

"""
    coldstart_main(args=ARGS) -> Int

Command entry point for the paired cold-start experiment.

The ordinary `main` entry point is intentionally not overloaded with this
protocol: `all check` means persistent integer ratchets, while cold-start
latency compares two checkouts in one run. A reusable workflow calls this
function directly.
"""
function coldstart_main(args::AbstractVector{<:AbstractString}=ARGS)
  isempty(args) && return _coldstart_usage()
  args[1] == "compare" || return _coldstart_usage("expected `compare`")

  base = ""
  head = pwd()
  ratchet_dir = "code_ratchet"
  output = ""
  i = 2
  while i <= length(args)
    flag = args[i]
    if flag == "--base"
      base = _coldstart_flag_value(args, i, flag)
      i += 2
    elseif flag == "--head"
      head = _coldstart_flag_value(args, i, flag)
      i += 2
    elseif flag == "--ratchet-dir"
      ratchet_dir = _coldstart_flag_value(args, i, flag)
      i += 2
    elseif flag == "--output"
      output = _coldstart_flag_value(args, i, flag)
      i += 2
    else
      return _coldstart_usage("unknown flag $(repr(flag))")
    end
  end
  isempty(base) && return _coldstart_usage("--base is required")

  report = try
    coldstart_compare(base, head; ratchet_dir, output_dir=output)
  catch err
    println(stderr, sprint(showerror, err))
    return 1
  end
  print(report)
  is_ci() && step_summary("### CodeRatchet coldstart\n\n" * coldstart_markdown(report))
  return ok(report) ? 0 : 1
end
