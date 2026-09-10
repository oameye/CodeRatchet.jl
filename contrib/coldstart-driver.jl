length(ARGS) in (2, 3) || error(
  "usage: coldstart-driver.jl PACKAGE SCENARIOS [SCENARIO]",
)

package_name, scenarios_path = ARGS[1:2]
occursin(r"^[A-Za-z][A-Za-z0-9_]*$", package_name) || error(
  "invalid Julia package name: $package_name"
)
isfile(scenarios_path) || error("scenario registry is not a file: $scenarios_path")

const import_started_ns = time_ns()
Core.eval(Main, Expr(:using, Expr(:., Symbol(package_name))))
const import_ns = time_ns() - import_started_ns

check(condition, message) = condition || error(message)
Base.include(Main, scenarios_path)
isdefined(Main, :PRECOMPILE_BENCHMARKS) || error(
  "scenarios must define PRECOMPILE_BENCHMARKS"
)
benchmarks = getfield(Main, :PRECOMPILE_BENCHMARKS)
benchmarks isa NamedTuple || error("PRECOMPILE_BENCHMARKS must be an ordered NamedTuple")
isempty(benchmarks) && error("PRECOMPILE_BENCHMARKS must not be empty")

if length(ARGS) == 2
  for name in keys(benchmarks)
    println("SCENARIO\t", name)
  end
  exit()
end

scenario_name = only(ARGS[3:3])
occursin(r"^[A-Za-z0-9][A-Za-z0-9_.-]*$", scenario_name) || error(
  "invalid cold-start scenario name: $scenario_name"
)
scenario_key = Symbol(scenario_name)
haskey(benchmarks, scenario_key) || error("unknown cold-start scenario: $scenario_name")
selected_scenario = benchmarks[scenario_key]
applicable(selected_scenario) || error(
  "cold-start scenario must be callable without arguments: $scenario_name"
)

# Compile the timing machinery before the first recorded workload. Julia's
# performance manual explicitly warns that the first timing invocation can pay
# for timing support itself; that cost is harness overhead, not package TTFX.
@timed nothing

first_result = @timed selected_scenario()
warm_result = @timed selected_scenario()

ns(seconds) = round(Int, seconds * 1.0e9)
first_ns = ns(first_result.time)
first_compile_ns = ns(first_result.compile_time)
first_recompile_ns = ns(first_result.recompile_time)
warm_ns = ns(warm_result.time)
warm_compile_ns = ns(warm_result.compile_time)
warm_recompile_ns = ns(warm_result.recompile_time)
total_ns = import_ns + first_ns

first_recompile_ns <= first_compile_ns || error(
  "first-use recompilation time exceeds compilation time"
)
warm_recompile_ns <= warm_compile_ns || error(
  "warm recompilation time exceeds compilation time"
)

println(
  join(
    Any[
      "RESULT",
      scenario_name,
      import_ns,
      first_ns,
      first_compile_ns,
      first_recompile_ns,
      total_ns,
      warm_ns,
      warm_compile_ns,
      warm_recompile_ns,
    ],
    '\t',
  ),
)
