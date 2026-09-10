"""
Paired cold-start measurements for one package revision against another.

This is deliberately not a [`Metric`](@ref). A `Metric` is a persistent,
per-file integer ratchet; wall-clock latency is noisy and only meaningful when
base and head are measured together on the same runner. `ColdStart` therefore
owns a second comparison protocol while sharing CodeRatchet's rule that a gate
must say exactly what moved and how to reproduce it.
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

ok(report::ColdStartReport) = all(v -> !v.failed, report.verdicts)

function _coldstart_positive(value, name::AbstractString)
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
  builds = _coldstart_positive(get(block, "builds", 2), "builds")
  samples = _coldstart_positive(get(block, "samples", 5), "samples")
  precompile_tasks =
    _coldstart_positive(get(block, "precompile_tasks", 1), "precompile_tasks")

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

function _median_int(values::Vector{Int})
  isempty(values) && error("cannot take the median of no cold-start samples")
  ordered = sort(copy(values))
  n = length(ordered)
  isodd(n) && return ordered[(n + 1) ÷ 2]
  lo, hi = ordered[n ÷ 2], ordered[n ÷ 2 + 1]
  return lo + (hi - lo) ÷ 2
end

function _material_threshold(config::ColdStartConfig, baseline_ns::Int)
  relative_ns = ceil(Int, config.relative * baseline_ns)
  return max(config.absolute_ns, relative_ns)
end

function _material_regression(config::ColdStartConfig, baseline_ns::Int, current_ns::Int)
  return current_ns - baseline_ns >= _material_threshold(config, baseline_ns)
end

function _build_record(builds, variant::AbstractString, build::Int)
  matches = [b for b in builds if b.variant == variant && b.build == build]
  length(matches) == 1 || error("cold-start result has $(length(matches)) $variant build-$build rows")
  return only(matches)
end

function _scenario_median(samples, variant::AbstractString, build::Int, scenario::AbstractString, key)
  rows = [
    s for s in samples
    if s.variant == variant && s.build == build && s.scenario == scenario
  ]
  isempty(rows) && error("cold-start result has no $variant build-$build/$scenario samples")
  return _median_int(Int[getproperty(row, key) for row in rows])
end

function _coldstart_verdicts(
  config::ColdStartConfig,
  scenarios::Vector{String},
  builds::Vector{ColdStartBuild},
  samples::Vector{ColdStartSample},
)
  verdicts = ColdStartVerdict[]

  base_precompile = Int[]
  head_precompile = Int[]
  precompile_regressions = 0
  for build in 1:config.builds
    base = _build_record(builds, "base", build).precompile_ns
    head = _build_record(builds, "head", build).precompile_ns
    push!(base_precompile, base)
    push!(head_precompile, head)
    _material_regression(config, base, head) && (precompile_regressions += 1)
  end
  push!(
    verdicts,
    ColdStartVerdict(
      "precompile",
      _median_int(base_precompile),
      _median_int(head_precompile),
      precompile_regressions,
      config.builds,
      precompile_regressions == config.builds,
    ),
  )

  for scenario in scenarios
    base_totals = Int[]
    head_totals = Int[]
    regressions = 0
    for build in 1:config.builds
      base = _scenario_median(samples, "base", build, scenario, :total_ns)
      head = _scenario_median(samples, "head", build, scenario, :total_ns)
      push!(base_totals, base)
      push!(head_totals, head)
      _material_regression(config, base, head) && (regressions += 1)
    end
    push!(
      verdicts,
      ColdStartVerdict(
        scenario,
        _median_int(base_totals),
        _median_int(head_totals),
        regressions,
        config.builds,
        regressions == config.builds,
      ),
    )
  end
  return verdicts
end

function _format_ns(ns::Int)
  ns >= 1_000_000_000 && return string(round(ns / 1.0e9; digits=3), " s")
  return string(round(ns / 1.0e6; digits=1), " ms")
end

function _delta_percent(now::Int, before::Int)
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
      _format_ns(verdict.baseline_ns),
      " | ",
      _format_ns(verdict.current_ns),
      " | ",
      _delta_percent(verdict.current_ns, verdict.baseline_ns),
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
  for verdict in report.verdicts
    println(
      io,
      "  ",
      rpad(verdict.subject, maximum(length(v.subject) for v in report.verdicts)),
      "  ",
      _format_ns(verdict.baseline_ns),
      " -> ",
      _format_ns(verdict.current_ns),
      "  ",
      _delta_percent(verdict.current_ns, verdict.baseline_ns),
      "  material ",
      verdict.regressed_builds,
      "/",
      verdict.compared_builds,
      verdict.failed ? "  FAIL" : "",
    )
  end
  return nothing
end

function _julia_command(args::Vector{String}; dir::AbstractString)
  cmd = `$(Base.julia_cmd()) --startup-file=no --history-file=no $args`
  return Cmd(cmd; dir=String(dir))
end

function _coldstart_env(
  cmd::Cmd,
  depot::AbstractString;
  offline::Bool=false,
  precompile_tasks::Int=1,
)
  env = Dict{String,String}(String(k) => String(v) for (k, v) in ENV)
  env["JULIA_DEPOT_PATH"] = String(depot)
  env["JULIA_NUM_THREADS"] = "1"
  env["OPENBLAS_NUM_THREADS"] = "1"
  env["JULIA_NUM_PRECOMPILE_TASKS"] = string(precompile_tasks)
  env["JULIA_PKG_PRECOMPILE_AUTO"] = "0"
  offline && (env["JULIA_PKG_OFFLINE"] = "true")
  return setenv(cmd, env)
end

const _PREPARE_ENVIRONMENT = raw"""
using Pkg
Pkg.autoprecompilation_enabled(false)
Pkg.activate(ARGS[1]; io=devnull)
Pkg.develop(path=ARGS[2]; io=devnull)
Pkg.instantiate(; io=devnull)
Pkg.precompile(; io=devnull)
"""

const _PRECOMPILE_ENVIRONMENT = raw"""
using Pkg
Pkg.autoprecompilation_enabled(false)
Pkg.activate(ARGS[1]; io=devnull)
started = time_ns()
Pkg.precompile(; io=devnull)
println("BUILD\t", time_ns() - started)
"""

function _prepare_environment(
  checkout::AbstractString,
  environment::AbstractString,
  depot::AbstractString,
  config::ColdStartConfig,
)
  mkpath(environment)
  cmd = _julia_command(
    ["-e", _PREPARE_ENVIRONMENT, String(environment), String(checkout)]; dir=checkout
  )
  run(_coldstart_env(cmd, depot; precompile_tasks=config.precompile_tasks))
  return nothing
end

function _package_cache_dirs(depot::AbstractString, package::AbstractString)
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

function _remove_package_cache(depot::AbstractString, package::AbstractString)
  for path in _package_cache_dirs(depot, package)
    rm(path; recursive=true, force=true)
  end
  return nothing
end

function _tree_bytes(root::AbstractString)
  total = 0
  for (dir, _, files) in walkdir(root)
    for file in files
      total += filesize(joinpath(dir, file))
    end
  end
  return total
end

function _package_cache_bytes(depot::AbstractString, package::AbstractString)
  return sum((_tree_bytes(path) for path in _package_cache_dirs(depot, package)); init=0)
end

function _layered_depot(first::AbstractString, second::AbstractString)
  return String(first) * string(Sys.iswindows() ? ';' : ':') * String(second)
end

function _precompile_environment(
  checkout::AbstractString,
  environment::AbstractString,
  run_depot::AbstractString,
  seed_depot::AbstractString,
  package::AbstractString,
  config::ColdStartConfig,
)
  mkpath(run_depot)
  cmd = _julia_command(
    ["-e", _PRECOMPILE_ENVIRONMENT, String(environment)]; dir=checkout
  )
  output = read(
    _coldstart_env(
      cmd,
      _layered_depot(run_depot, seed_depot);
      offline=true,
      precompile_tasks=config.precompile_tasks,
    ),
    String,
  )
  rows = filter(line -> startswith(line, "BUILD\t"), split(chomp(output), '\n'))
  length(rows) == 1 || error("cold-start precompile emitted $(length(rows)) BUILD rows")
  fields = split(only(rows), '\t')
  length(fields) == 2 || error("malformed cold-start BUILD row")
  elapsed = parse(Int, fields[2])
  return elapsed, _package_cache_bytes(run_depot, package)
end

function _driver_path()
  source = pathof(@__MODULE__)
  source === nothing && error("cannot locate the CodeRatchet package root")
  return joinpath(dirname(dirname(source)), "contrib", "coldstart-driver.jl")
end

function _driver_output(
  checkout::AbstractString,
  environment::AbstractString,
  depot::AbstractString,
  package::AbstractString,
  scenarios::AbstractString,
  config::ColdStartConfig;
  scenario::AbstractString="",
)
  args = String[_driver_path(), String(package), String(scenarios)]
  isempty(scenario) || push!(args, String(scenario))
  cmd = _julia_command(args; dir=checkout)
  return read(
    _coldstart_env(
      cmd, depot; offline=true, precompile_tasks=config.precompile_tasks
    ),
    String,
  )
end

function _discover_scenarios(
  checkout,
  environment,
  depot,
  package,
  scenario_file,
  config::ColdStartConfig,
)
  output = _driver_output(
    checkout, environment, depot, package, scenario_file, config
  )
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

function _parse_sample(
  output::AbstractString,
  variant::AbstractString,
  build::Int,
  sample::Int,
  expected_scenario::AbstractString,
)
  rows = filter(line -> startswith(line, "RESULT\t"), split(chomp(output), '\n'))
  length(rows) == 1 || error("cold-start scenario emitted $(length(rows)) RESULT rows")
  fields = split(only(rows), '\t')
  length(fields) == 10 || error("malformed cold-start RESULT row")
  fields[2] == expected_scenario || error(
    "cold-start RESULT named $(fields[2]); expected $expected_scenario"
  )
  values = parse.(Int, fields[3:end])
  return ColdStartSample(
    String(variant),
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

function _scenario_sample(
  checkout,
  environment,
  depot,
  package,
  scenario_file,
  scenario,
  config,
  variant,
  build,
  sample,
)
  output = _driver_output(
    checkout,
    environment,
    depot,
    package,
    scenario_file,
    config;
    scenario,
  )
  return _parse_sample(output, variant, build, sample, scenario)
end

function _project_identity(root::AbstractString)
  project = TOML.parsefile(joinpath(root, "Project.toml"))
  name = get(project, "name", nothing)
  uuid = get(project, "uuid", nothing)
  name isa String && uuid isa String || error(
    "$root/Project.toml must define string name and uuid fields"
  )
  return (name=name, uuid=uuid)
end

function _full_commit(root::AbstractString)
  try
    return strip(read(Cmd(`git rev-parse HEAD`; dir=root), String))
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
        io,
        row.variant,
        '\t',
        row.build,
        '\t',
        row.precompile_ns,
        '\t',
        row.cache_bytes,
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
  open(joinpath(output_dir, "metadata.txt"), "w") do io
    println(io, "julia=", VERSION)
    println(io, "sysimage_target=", Sys.sysimage_target())
    println(io, "machine=", Sys.MACHINE)
    println(io, "base_commit=", _full_commit(base))
    println(io, "head_commit=", _full_commit(head))
    println(io, "builds=", report.config.builds)
    println(io, "samples=", report.config.samples)
    println(io, "absolute_ns=", report.config.absolute_ns)
    println(io, "relative=", report.config.relative)
    println(io, "precompile_tasks=", report.config.precompile_tasks)
  end
  return String(output_dir)
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
  base = realpath(base)
  head = realpath(head)

  base_identity = _project_identity(base)
  head_identity = _project_identity(head)
  base_identity == head_identity || error(
    "cold-start checkouts name different packages: $base_identity != $head_identity"
  )
  package = head_identity.name

  config_dir = isabspath(ratchet_dir) ? String(ratchet_dir) : joinpath(head, ratchet_dir)
  config = coldstart_config(head; dir=config_dir)
  scenario_file =
    isabspath(config.scenarios) ? config.scenarios : joinpath(head, config.scenarios)
  isfile(scenario_file) || error("cold-start scenario registry not found: $scenario_file")

  builds = ColdStartBuild[]
  samples = ColdStartSample[]
  scenarios = String[]

  mktempdir() do temporary
    seed_depot = joinpath(temporary, "seed-depot")
    base_environment = joinpath(temporary, "base-environment")
    head_environment = joinpath(temporary, "head-environment")
    mkpath(seed_depot)

    _prepare_environment(base, base_environment, seed_depot, config)
    _remove_package_cache(seed_depot, package)
    _prepare_environment(head, head_environment, seed_depot, config)
    _remove_package_cache(seed_depot, package)

    discovery_depot = joinpath(temporary, "discovery-depot")
    mkpath(discovery_depot)
    scenarios = _discover_scenarios(
      head,
      head_environment,
      _layered_depot(discovery_depot, seed_depot),
      package,
      scenario_file,
      config,
    )

    # Equal discarded work before either side is measured. This absorbs the
    # one-time filesystem/LLVM effects of generating this package's cache.
    for (variant, checkout, environment) in (
      ("base", base, base_environment), ("head", head, head_environment)
    )
      warmup_depot = joinpath(temporary, "warmup-" * variant)
      _precompile_environment(
        checkout, environment, warmup_depot, seed_depot, package, config
      )
    end

    for build in 1:config.builds
      order = isodd(build) ? ("base", "head") : ("head", "base")
      for variant in order
        checkout = variant == "base" ? base : head
        environment = variant == "base" ? base_environment : head_environment
        run_depot = joinpath(temporary, "run-$build-$variant")
        precompile_ns, cache_bytes = _precompile_environment(
          checkout, environment, run_depot, seed_depot, package, config
        )
        push!(builds, ColdStartBuild(variant, build, precompile_ns, cache_bytes))

        layered = _layered_depot(run_depot, seed_depot)
        for scenario in scenarios
          # Discard one process after the cache build to absorb filesystem page
          # population and driver compilation before recorded samples begin.
          _scenario_sample(
            checkout,
            environment,
            layered,
            package,
            scenario_file,
            scenario,
            config,
            variant,
            build,
            0,
          )
          for sample in 1:config.samples
            push!(
              samples,
              _scenario_sample(
                checkout,
                environment,
                layered,
                package,
                scenario_file,
                scenario,
                config,
                variant,
                build,
                sample,
              ),
            )
          end
        end
      end
    end
  end

  verdicts = _coldstart_verdicts(config, scenarios, builds, samples)
  report = ColdStartReport(config, scenarios, builds, samples, verdicts)
  isempty(output_dir) || write_coldstart_results(report, output_dir, base, head)
  return report
end
