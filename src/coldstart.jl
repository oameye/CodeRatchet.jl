"""
Paired cold-start measurements for one package revision against another.

This is deliberately not a [`Metric`](@ref). A `Metric` is a persistent,
per-file integer ratchet; wall-clock latency is noisy and only meaningful when
base and head are measured together on the same runner. The cold-start
subsystem therefore owns a second comparison protocol while sharing
CodeRatchet's rule that a gate must say exactly what moved and how to reproduce
it.
"""

struct ColdStartConfig
  scenarios::String
  builds::Int
  samples::Int
  absolute_ns::Int
  relative::Float64
  precompile_tasks::Int
end

struct ColdStartBuild
  variant::String
  build::Int
  precompile_ns::Int
  cache_bytes::Int
end

struct ColdStartSample
  variant::String
  build::Int
  sample::Int
  scenario::String
  import_ns::Int
  first_ns::Int
  compile_ns::Int
  recompile_ns::Int
  total_ns::Int
  warm_ns::Int
  warm_compile_ns::Int
  warm_recompile_ns::Int
end

struct ColdStartVerdict
  subject::String
  baseline_ns::Int
  current_ns::Int
  regressed_builds::Int
  compared_builds::Int
  failed::Bool
end

struct ColdStartReport
  config::ColdStartConfig
  scenarios::Vector{String}
  builds::Vector{ColdStartBuild}
  samples::Vector{ColdStartSample}
  verdicts::Vector{ColdStartVerdict}
end

struct ColdStartTarget
  variant::String
  checkout::String
  environment::String
end

struct ColdStartContext
  package::String
  scenario_file::String
  config::ColdStartConfig
  seed_depot::String
  scenarios::Vector{String}
end

ok(report::ColdStartReport) = all(verdict -> !verdict.failed, report.verdicts)

function coldstart_positive(value, name::AbstractString)
  n = try
    Int(value)
  catch
    error("[coldstart] $name must be an integer")
  end
  n > 0 || error("[coldstart] $name must be positive")
  return n
end

"""
    coldstart_config(root; dir) -> ColdStartConfig

Read the `[coldstart]` block. The defaults are intentionally conservative: two
independent cache builds, five fresh processes per workload, and a material
regression floor of both 50 ms and 5%.

`precompile_tasks = 1` trades throughput for comparability. Package
precompilation is parallel by default; a fixed single worker makes a paired CI
measurement substantially less sensitive to what else the runner is doing.
"""
function coldstart_config(
  root::AbstractString=pwd(); dir::AbstractString=joinpath(root, "code_ratchet")
)
  block = get(read_rulings(dir).raw, "coldstart", Dict{String,Any}())
  scenarios = String(get(block, "scenarios", "benchmark/precompile/scenarios.jl"))
  builds = coldstart_positive(get(block, "builds", 2), "builds")
  samples = coldstart_positive(get(block, "samples", 5), "samples")
  precompile_tasks = coldstart_positive(
    get(block, "precompile_tasks", 1), "precompile_tasks"
  )

  absolute_ms = try
    Float64(get(block, "absolute_ms", 50.0))
  catch
    error("[coldstart] absolute_ms must be numeric")
  end
  absolute_ms >= 0 || error("[coldstart] absolute_ms must be nonnegative")

  relative = try
    Float64(get(block, "relative", 0.05))
  catch
    error("[coldstart] relative must be numeric")
  end
  0 <= relative < 1 || error("[coldstart] relative must satisfy 0 <= relative < 1")

  return ColdStartConfig(
    scenarios,
    builds,
    samples,
    round(Int, absolute_ms * 1_000_000),
    relative,
    precompile_tasks,
  )
end

function median_int(values::Vector{Int})
  isempty(values) && error("cannot take the median of no cold-start samples")
  ordered = sort(copy(values))
  n = length(ordered)
  isodd(n) && return ordered[(n + 1) ÷ 2]
  lo, hi = ordered[n ÷ 2], ordered[n ÷ 2 + 1]
  return lo + (hi - lo) ÷ 2
end

function material_threshold(config::ColdStartConfig, baseline_ns::Int)
  relative_ns = ceil(Int, config.relative * baseline_ns)
  return max(config.absolute_ns, relative_ns)
end

function material_regression(config::ColdStartConfig, baseline_ns::Int, current_ns::Int)
  return current_ns - baseline_ns >= material_threshold(config, baseline_ns)
end

function build_record(builds::Vector{ColdStartBuild}, variant::AbstractString, build::Int)
  matches = [row for row in builds if row.variant == variant && row.build == build]
  length(matches) == 1 ||
    error("cold-start result has $(length(matches)) $variant build-$build rows")
  return only(matches)
end

function scenario_median(
  samples::Vector{ColdStartSample},
  variant::AbstractString,
  build::Int,
  scenario::AbstractString,
  key::Symbol,
)
  rows = [
    row for row in samples if
    row.variant == variant && row.build == build && row.scenario == scenario
  ]
  isempty(rows) && error("cold-start result has no $variant build-$build/$scenario samples")
  return median_int(Int[getproperty(row, key) for row in rows])
end

function precompile_verdict(config::ColdStartConfig, builds::Vector{ColdStartBuild})
  baseline = Int[]
  current = Int[]
  regressions = 0
  for build in 1:config.builds
    base_ns = build_record(builds, "base", build).precompile_ns
    head_ns = build_record(builds, "head", build).precompile_ns
    push!(baseline, base_ns)
    push!(current, head_ns)
    material_regression(config, base_ns, head_ns) && (regressions += 1)
  end
  return ColdStartVerdict(
    "precompile",
    median_int(baseline),
    median_int(current),
    regressions,
    config.builds,
    regressions == config.builds,
  )
end

function scenario_verdict(
  config::ColdStartConfig, samples::Vector{ColdStartSample}, scenario::AbstractString
)
  baseline = Int[]
  current = Int[]
  regressions = 0
  for build in 1:config.builds
    base_ns = scenario_median(samples, "base", build, scenario, :total_ns)
    head_ns = scenario_median(samples, "head", build, scenario, :total_ns)
    push!(baseline, base_ns)
    push!(current, head_ns)
    material_regression(config, base_ns, head_ns) && (regressions += 1)
  end
  return ColdStartVerdict(
    String(scenario),
    median_int(baseline),
    median_int(current),
    regressions,
    config.builds,
    regressions == config.builds,
  )
end

function coldstart_verdicts(
  config::ColdStartConfig,
  scenarios::Vector{String},
  builds::Vector{ColdStartBuild},
  samples::Vector{ColdStartSample},
)
  verdicts = ColdStartVerdict[precompile_verdict(config, builds)]
  append!(verdicts, [scenario_verdict(config, samples, scenario) for scenario in scenarios])
  return verdicts
end

function format_ns(ns::Int)
  ns >= 1_000_000_000 && return string(round(ns / 1.0e9; digits=3), " s")
  return string(round(ns / 1.0e6; digits=1), " ms")
end

function delta_percent(now::Int, before::Int)
  iszero(before) && return "n/a"
  value = round(100 * (now - before) / before; digits=1)
  return (value > 0 ? "+" : "") * string(value) * "%"
end

function coldstart_markdown(report::ColdStartReport)
  io = IOBuffer()
  println(io, "| signal | base | head | delta | material builds | gate |")
  println(io, "| --- | ---: | ---: | ---: | ---: | --- |")
  for verdict in report.verdicts
    println(
      io,
      "| ",
      verdict.subject,
      " | ",
      format_ns(verdict.baseline_ns),
      " | ",
      format_ns(verdict.current_ns),
      " | ",
      delta_percent(verdict.current_ns, verdict.baseline_ns),
      " | ",
      verdict.regressed_builds,
      "/",
      verdict.compared_builds,
      " | ",
      verdict.failed ? "FAIL" : "PASS",
      " |",
    )
  end
  return String(take!(io))
end

function Base.show(io::IO, report::ColdStartReport)
  println(io, "CodeRatchet coldstart: ", ok(report) ? "PASS" : "FAIL")
  width = maximum(length(verdict.subject) for verdict in report.verdicts)
  for verdict in report.verdicts
    println(
      io,
      "  ",
      rpad(verdict.subject, width),
      "  ",
      format_ns(verdict.baseline_ns),
      " -> ",
      format_ns(verdict.current_ns),
      "  ",
      delta_percent(verdict.current_ns, verdict.baseline_ns),
      "  material ",
      verdict.regressed_builds,
      "/",
      verdict.compared_builds,
      verdict.failed ? "  FAIL" : "",
    )
  end
  return nothing
end

"""
    julia_command(args; dir) -> Cmd

A clean Julia child command using the current executable, not the current
process flags. `Base.julia_cmd()` deliberately carries options such as coverage,
check-bounds and debug level into subprocesses; inheriting those would make a
cold-start result depend on how CodeRatchet itself happened to be launched.
"""
function julia_command(args::Vector{String}; dir::AbstractString)
  executable = joinpath(Sys.BINDIR, Base.julia_exename())
  cmd = `$executable --startup-file=no --history-file=no $args`
  return Cmd(cmd; dir=String(dir))
end

function coldstart_env(
  cmd::Cmd, depot::AbstractString; offline::Bool=false, precompile_tasks::Int=1
)
  env = Dict{String,String}(String(key) => String(value) for (key, value) in ENV)
  env["JULIA_DEPOT_PATH"] = String(depot)
  # Pkg.test and some CI harnesses deliberately narrow JULIA_LOAD_PATH. A
  # cold-start child must not inherit that process-local choice or even stdlibs
  # such as Pkg can disappear. The measured package itself is supplied by an
  # explicit --project below.
  env["JULIA_LOAD_PATH"] = "@:@stdlib"
  env["JULIA_NUM_THREADS"] = "1"
  env["OPENBLAS_NUM_THREADS"] = "1"
  env["JULIA_NUM_PRECOMPILE_TASKS"] = string(precompile_tasks)
  env["JULIA_PKG_PRECOMPILE_AUTO"] = "0"
  offline && (env["JULIA_PKG_OFFLINE"] = "true")
  return setenv(cmd, env)
end

# JULIA_PKG_PRECOMPILE_AUTO=0 is set before these children start. That keeps
# this protocol usable on Julia 1.12 too; Pkg.autoprecompilation_enabled(false)
# is a 1.13 API and would unnecessarily raise CodeRatchet's compatibility floor.
const PREPARE_ENVIRONMENT = raw"""
using Pkg
Pkg.activate(ARGS[1]; io=devnull)
Pkg.develop(path=ARGS[2]; io=devnull)
Pkg.instantiate(; io=devnull)
Pkg.precompile(; io=devnull)
"""

const PRECOMPILE_ENVIRONMENT = raw"""
using Pkg
Pkg.activate(ARGS[1]; io=devnull)
started = time_ns()
Pkg.precompile(; io=devnull)
println("BUILD\t", time_ns() - started)
"""

function prepare_environment(
  target::ColdStartTarget, depot::AbstractString, config::ColdStartConfig
)
  mkpath(target.environment)
  cmd = julia_command(
    ["-e", PREPARE_ENVIRONMENT, target.environment, target.checkout]; dir=target.checkout
  )
  run(coldstart_env(cmd, depot; precompile_tasks=config.precompile_tasks))
  return nothing
end

function package_cache_dirs(depot::AbstractString, package::AbstractString)
  compiled = joinpath(depot, "compiled")
  isdir(compiled) || return String[]
  found = String[]
  for (dir, dirs, _) in walkdir(compiled)
    for child in dirs
      child == package && push!(found, joinpath(dir, child))
    end
  end
  return unique(found)
end

function remove_package_cache(depot::AbstractString, package::AbstractString)
  for path in package_cache_dirs(depot, package)
    rm(path; recursive=true, force=true)
  end
  return nothing
end

function tree_bytes(root::AbstractString)
  total = 0
  for (dir, _, files) in walkdir(root)
    for file in files
      total += filesize(joinpath(dir, file))
    end
  end
  return total
end

function package_cache_bytes(depot::AbstractString, package::AbstractString)
  return sum((tree_bytes(path) for path in package_cache_dirs(depot, package)); init=0)
end

function layered_depot(first::AbstractString, second::AbstractString)
  return String(first) * string(Sys.iswindows() ? ';' : ':') * String(second)
end

function precompile_environment(
  target::ColdStartTarget, context::ColdStartContext, run_depot::AbstractString
)
  mkpath(run_depot)
  cmd = julia_command(
    ["-e", PRECOMPILE_ENVIRONMENT, target.environment]; dir=target.checkout
  )
  output = read(
    coldstart_env(
      cmd,
      layered_depot(run_depot, context.seed_depot);
      offline=true,
      precompile_tasks=context.config.precompile_tasks,
    ),
    String,
  )
  rows = filter(line -> startswith(line, "BUILD\t"), split(chomp(output), '\n'))
  length(rows) == 1 || error("cold-start precompile emitted $(length(rows)) BUILD rows")
  fields = split(only(rows), '\t')
  length(fields) == 2 || error("malformed cold-start BUILD row")
  elapsed = parse(Int, fields[2])
  return elapsed, package_cache_bytes(run_depot, context.package)
end

function driver_path()
  source = pathof(@__MODULE__)
  source === nothing && error("cannot locate the CodeRatchet package root")
  return joinpath(dirname(dirname(source)), "contrib", "coldstart-driver.jl")
end

function driver_output(
  target::ColdStartTarget,
  context::ColdStartContext,
  depot::AbstractString;
  scenario::AbstractString="",
)
  args = String[
    "--project=$(target.environment)", driver_path(), context.package, context.scenario_file
  ]
  isempty(scenario) || push!(args, String(scenario))
  cmd = julia_command(args; dir=target.checkout)
  return read(
    coldstart_env(
      cmd, depot; offline=true, precompile_tasks=context.config.precompile_tasks
    ),
    String,
  )
end

function discover_scenarios(
  target::ColdStartTarget, context::ColdStartContext, depot::AbstractString
)
  output = driver_output(target, context, depot)
  names = String[]
  for line in split(chomp(output), '\n')
    startswith(line, "SCENARIO\t") || continue
    fields = split(line, '\t')
    length(fields) == 2 || error("malformed SCENARIO row")
    push!(names, String(fields[2]))
  end
  isempty(names) && error("PRECOMPILE_BENCHMARKS must define at least one scenario")
  allunique(names) || error("PRECOMPILE_BENCHMARKS contains duplicate scenario names")
  return names
end

function parse_sample(
  output::AbstractString,
  target::ColdStartTarget,
  build::Int,
  sample::Int,
  expected_scenario::AbstractString,
)
  rows = filter(line -> startswith(line, "RESULT\t"), split(chomp(output), '\n'))
  length(rows) == 1 || error("cold-start scenario emitted $(length(rows)) RESULT rows")
  fields = split(only(rows), '\t')
  length(fields) == 10 || error("malformed cold-start RESULT row")
  fields[2] == expected_scenario ||
    error("cold-start RESULT named $(fields[2]); expected $expected_scenario")
  values = parse.(Int, fields[3:end])
  return ColdStartSample(
    target.variant,
    build,
    sample,
    String(expected_scenario),
    values[1],
    values[2],
    values[3],
    values[4],
    values[5],
    values[6],
    values[7],
    values[8],
  )
end

function scenario_sample(
  target::ColdStartTarget,
  context::ColdStartContext,
  depot::AbstractString,
  scenario::AbstractString,
  build::Int,
  sample::Int,
)
  output = driver_output(target, context, depot; scenario)
  return parse_sample(output, target, build, sample, scenario)
end

function project_identity(root::AbstractString)
  project = TOML.parsefile(joinpath(root, "Project.toml"))
  name = get(project, "name", nothing)
  uuid = get(project, "uuid", nothing)
  name isa String && uuid isa String ||
    error("$root/Project.toml must define string name and uuid fields")
  return (name=name, uuid=uuid)
end

function full_commit(root::AbstractString)
  try
    command = pipeline(Cmd(`git rev-parse HEAD`; dir=root); stderr=devnull)
    return strip(read(command, String))
  catch
    return "unknown"
  end
end

function coldstart_file_hash(path::AbstractString)
  try
    command = pipeline(`git hash-object --no-filters $path`; stderr=devnull)
    return strip(read(command, String))
  catch
    return "unknown"
  end
end

function write_coldstart_results(
  report::ColdStartReport,
  output_dir::AbstractString,
  base::AbstractString,
  head::AbstractString,
)
  mkpath(output_dir)

  open(joinpath(output_dir, "builds.tsv"), "w") do io
    println(io, "variant\tbuild\tprecompile_ns\tcache_bytes")
    for row in report.builds
      println(
        io, row.variant, '\t', row.build, '\t', row.precompile_ns, '\t', row.cache_bytes
      )
    end
  end

  open(joinpath(output_dir, "samples.tsv"), "w") do io
    println(
      io,
      "variant\tbuild\tsample\tscenario\timport_ns\tfirst_ns\tcompile_ns\t" *
      "recompile_ns\ttotal_ns\twarm_ns\twarm_compile_ns\twarm_recompile_ns",
    )
    for row in report.samples
      println(
        io,
        join(
          Any[
            row.variant,
            row.build,
            row.sample,
            row.scenario,
            row.import_ns,
            row.first_ns,
            row.compile_ns,
            row.recompile_ns,
            row.total_ns,
            row.warm_ns,
            row.warm_compile_ns,
            row.warm_recompile_ns,
          ],
          '\t',
        ),
      )
    end
  end

  write(joinpath(output_dir, "summary.md"), coldstart_markdown(report))
  scenario_file =
    isabspath(report.config.scenarios) ? report.config.scenarios : joinpath(head, report.config.scenarios)
  open(joinpath(output_dir, "metadata.txt"), "w") do io
    println(io, "julia=", VERSION)
    println(io, "sysimage_target=", Sys.sysimage_target())
    println(io, "machine=", Sys.MACHINE)
    println(io, "runner_image=", get(ENV, "ImageVersion", "unknown"))
    println(io, "base_commit=", full_commit(base))
    println(io, "head_commit=", full_commit(head))
    println(io, "scenario_hash=", coldstart_file_hash(scenario_file))
    println(io, "builds=", report.config.builds)
    println(io, "samples=", report.config.samples)
    println(io, "absolute_ns=", report.config.absolute_ns)
    println(io, "relative=", report.config.relative)
    return println(io, "precompile_tasks=", report.config.precompile_tasks)
  end
  return String(output_dir)
end

function initial_context(
  package::AbstractString,
  scenario_file::AbstractString,
  config::ColdStartConfig,
  seed_depot::AbstractString,
)
  return ColdStartContext(
    String(package), String(scenario_file), config, String(seed_depot), String[]
  )
end

function run_context(context::ColdStartContext, scenarios::Vector{String})
  return ColdStartContext(
    context.package, context.scenario_file, context.config, context.seed_depot, scenarios
  )
end

function warmup_target(
  target::ColdStartTarget, context::ColdStartContext, temporary::AbstractString
)
  warmup_depot = joinpath(temporary, "warmup-" * target.variant)
  precompile_environment(target, context, warmup_depot)
  return nothing
end

function measure_target!(
  builds::Vector{ColdStartBuild},
  samples::Vector{ColdStartSample},
  target::ColdStartTarget,
  context::ColdStartContext,
  temporary::AbstractString,
  build::Int,
)
  run_depot = joinpath(temporary, "run-$build-$(target.variant)")
  precompile_ns, cache_bytes = precompile_environment(target, context, run_depot)
  push!(builds, ColdStartBuild(target.variant, build, precompile_ns, cache_bytes))

  depot = layered_depot(run_depot, context.seed_depot)
  for scenario in context.scenarios
    scenario_sample(target, context, depot, scenario, build, 0)
    for sample in 1:context.config.samples
      push!(samples, scenario_sample(target, context, depot, scenario, build, sample))
    end
  end
  return nothing
end

function measure_build!(
  builds::Vector{ColdStartBuild},
  samples::Vector{ColdStartSample},
  targets::NTuple{2,ColdStartTarget},
  context::ColdStartContext,
  temporary::AbstractString,
  build::Int,
)
  order = isodd(build) ? targets : reverse(targets)
  for target in order
    measure_target!(builds, samples, target, context, temporary, build)
  end
  return nothing
end

function run_coldstart_experiment(
  base::AbstractString,
  head::AbstractString,
  package::AbstractString,
  scenario_file::AbstractString,
  config::ColdStartConfig,
  temporary::AbstractString,
)
  seed_depot = joinpath(temporary, "seed-depot")
  mkpath(seed_depot)

  base_target = ColdStartTarget(
    "base", String(base), joinpath(temporary, "base-environment")
  )
  head_target = ColdStartTarget(
    "head", String(head), joinpath(temporary, "head-environment")
  )
  targets = (base_target, head_target)

  for target in targets
    prepare_environment(target, seed_depot, config)
    remove_package_cache(seed_depot, package)
  end

  setup = initial_context(package, scenario_file, config, seed_depot)
  discovery_depot = joinpath(temporary, "discovery-depot")
  mkpath(discovery_depot)
  scenarios = discover_scenarios(
    head_target, setup, layered_depot(discovery_depot, seed_depot)
  )
  context = run_context(setup, scenarios)

  for target in targets
    warmup_target(target, context, temporary)
  end

  builds = ColdStartBuild[]
  samples = ColdStartSample[]
  for build in 1:config.builds
    measure_build!(builds, samples, targets, context, temporary, build)
  end
  return scenarios, builds, samples
end

"""
    coldstart_compare(base, head; ratchet_dir="code_ratchet", output_dir="")

Compare two committed package checkouts on the current Julia runtime.

The experiment owns fresh temporary depots. Dependency installation and one
unmeasured package-cache build happen first. Each measured build then gets a
fresh writable depot layered over the seeded dependency depot. Build order
alternates base/head then head/base to reduce monotonic runner drift, and every
scenario sample runs in a fresh Julia process.

Only target-package precompile time and total time-to-first-execution bind in
this first version. Import, compilation, recompilation, warm latency and cache
size are recorded as diagnostic context. A signal fails only when every
independent build regresses by at least `max(absolute_ms, relative * base)`.
"""
function coldstart_compare(
  base::AbstractString,
  head::AbstractString;
  ratchet_dir::AbstractString="code_ratchet",
  output_dir::AbstractString="",
)
  isdir(base) || error("cold-start base checkout does not exist: $base")
  isdir(head) || error("cold-start head checkout does not exist: $head")
  base_path = realpath(base)
  head_path = realpath(head)

  base_identity = project_identity(base_path)
  head_identity = project_identity(head_path)
  base_identity == head_identity ||
    error("cold-start checkouts name different packages: $base_identity != $head_identity")
  package = head_identity.name

  config_dir =
    isabspath(ratchet_dir) ? String(ratchet_dir) : joinpath(head_path, ratchet_dir)
  config = coldstart_config(head_path; dir=config_dir)
  scenario_file =
    isabspath(config.scenarios) ? config.scenarios : joinpath(head_path, config.scenarios)
  isfile(scenario_file) || error("cold-start scenario registry not found: $scenario_file")

  scenarios, builds, samples = mktempdir() do temporary
    return run_coldstart_experiment(
      base_path, head_path, package, scenario_file, config, temporary
    )
  end

  verdicts = coldstart_verdicts(config, scenarios, builds, samples)
  report = ColdStartReport(config, scenarios, builds, samples, verdicts)
  isempty(output_dir) || write_coldstart_results(report, output_dir, base_path, head_path)
  return report
end
