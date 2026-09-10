export coldstart_compare, coldstart_main

mutable struct ColdStartCLIOptions
  base::String
  head::String
  ratchet_dir::String
  output::String
end

ColdStartCLIOptions() = ColdStartCLIOptions("", pwd(), "code_ratchet", "")

function coldstart_usage(problem::AbstractString="")
  isempty(problem) || println(stderr, "coderatchet coldstart: ", problem)
  println(
    stderr,
    "usage: coderatchet coldstart compare --base PATH [--head PATH] " *
    "[--ratchet-dir PATH] [--output PATH]",
  )
  return 2
end

function coldstart_flag_value(args, index, flag)
  index < length(args) || throw(ArgumentError("$flag needs a value"))
  return String(args[index + 1])
end

function set_coldstart_option!(
  options::ColdStartCLIOptions, flag::AbstractString, value::String
)
  if flag == "--base"
    options.base = value
  elseif flag == "--head"
    options.head = value
  elseif flag == "--ratchet-dir"
    options.ratchet_dir = value
  elseif flag == "--output"
    options.output = value
  else
    throw(ArgumentError("unknown flag $(repr(flag))"))
  end
  return options
end

function parse_coldstart_options(args::AbstractVector{<:AbstractString})
  options = ColdStartCLIOptions()
  index = 2
  while index <= length(args)
    flag = String(args[index])
    value = coldstart_flag_value(args, index, flag)
    set_coldstart_option!(options, flag, value)
    index += 2
  end
  isempty(options.base) && throw(ArgumentError("--base is required"))
  return options
end

function coldstart_report(options::ColdStartCLIOptions)
  return coldstart_compare(
    options.base, options.head; ratchet_dir=options.ratchet_dir, output_dir=options.output
  )
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
  isempty(args) && return coldstart_usage()
  args[1] == "compare" || return coldstart_usage("expected `compare`")

  options = try
    parse_coldstart_options(args)
  catch err
    err isa ArgumentError || rethrow()
    return coldstart_usage(err.msg)
  end

  report = try
    coldstart_report(options)
  catch err
    println(stderr, sprint(showerror, err))
    return 1
  end
  print(report)
  is_ci() && step_summary("### CodeRatchet coldstart\n\n" * coldstart_markdown(report))
  return ok(report) ? 0 : 1
end
