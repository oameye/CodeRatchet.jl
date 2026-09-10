from pathlib import Path
import re


def replace_once(text, old, new, label):
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected one match, found {count}")
    return text.replace(old, new, 1)


project_path = Path("Project.toml")
project = project_path.read_text()
project = replace_once(
    project,
    'JuliaSyntax = "70703baa-626e-46a2-a12c-08ffd08c73b4"\nTOML = "fa267f1f-6049-4f14-aa54-33bafae1ed76"',
    'JuliaSyntax = "70703baa-626e-46a2-a12c-08ffd08c73b4"\nSHA = "ea8e919c-243c-51af-8825-aaa63cd721ce"\nTOML = "fa267f1f-6049-4f14-aa54-33bafae1ed76"',
    "SHA dependency",
)
project = replace_once(
    project,
    'JuliaSyntax = "1"\nTOML = "1"',
    'JuliaSyntax = "1"\nSHA = "0.7, 1"\nTOML = "1"',
    "SHA compat",
)
project_path.write_text(project)

path = Path("src/coldstart.jl")
text = path.read_text()
if not text.startswith("using SHA: sha256\n"):
    text = "using SHA: sha256\n\n" + text

text = replace_once(
    text,
    '''struct ColdStartReport
  config::ColdStartConfig
  scenarios::Vector{String}
  builds::Vector{ColdStartBuild}
  samples::Vector{ColdStartSample}
  verdicts::Vector{ColdStartVerdict}
end

struct ColdStartTarget''',
    '''struct ColdStartEnvironment
  variant::String
  project::String
  manifest::String
end

struct ColdStartReport
  config::ColdStartConfig
  scenarios::Vector{String}
  builds::Vector{ColdStartBuild}
  samples::Vector{ColdStartSample}
  verdicts::Vector{ColdStartVerdict}
  environments::Vector{ColdStartEnvironment}
end

function ColdStartReport(
  config::ColdStartConfig,
  scenarios::Vector{String},
  builds::Vector{ColdStartBuild},
  samples::Vector{ColdStartSample},
  verdicts::Vector{ColdStartVerdict},
)
  return ColdStartReport(
    config, scenarios, builds, samples, verdicts, ColdStartEnvironment[]
  )
end

struct ColdStartTarget''',
    "environment provenance model",
)

marker = '''end

function median_int(values::Vector{Int})'''
insertion = '''end

function has_coldstart_block(dir::AbstractString)
  path = joinpath(dir, RULINGS)
  isfile(path) || return false
  return haskey(TOML.parsefile(path), "coldstart")
end

function coldstart_config_selection(
  base::AbstractString, head::AbstractString, ratchet_dir::AbstractString
)
  if isabspath(ratchet_dir)
    dir = String(ratchet_dir)
    return (config=coldstart_config(head; dir), source="absolute")
  end

  base_dir = joinpath(base, ratchet_dir)
  head_dir = joinpath(head, ratchet_dir)
  if has_coldstart_block(base_dir)
    return (config=coldstart_config(base; dir=base_dir), source="base")
  end
  if has_coldstart_block(head_dir)
    return (config=coldstart_config(head; dir=head_dir), source="head-bootstrap")
  end

  base_rulings = joinpath(base_dir, RULINGS)
  isfile(base_rulings) &&
    return (config=coldstart_config(base; dir=base_dir), source="base-default")
  head_rulings = joinpath(head_dir, RULINGS)
  isfile(head_rulings) &&
    return (config=coldstart_config(head; dir=head_dir), source="head-default")
  error("cold-start rulings not found under base or head: $(String(ratchet_dir))")
end

function median_int(values::Vector{Int})'''
text = replace_once(text, marker, insertion, "config selection insertion")

text = replace_once(
    text,
    '''function julia_command(args::Vector{String}; dir::AbstractString)
  executable = joinpath(Sys.BINDIR, Base.julia_exename())
  cmd = `$executable --startup-file=no --history-file=no $args`
  return Cmd(cmd; dir=String(dir))
end''',
    '''function julia_command(
  args::Vector{String}; dir::AbstractString, existing_caches::Bool=false
)
  executable = joinpath(Sys.BINDIR, Base.julia_exename())
  cache_args = existing_caches ? ["--compiled-modules=existing", "--pkgimages=existing"] : String[]
  cmd = `$executable --startup-file=no --history-file=no $cache_args $args`
  return Cmd(cmd; dir=String(dir))
end''',
    "existing-only cache command",
)

text = replace_once(
    text,
    '''const PRECOMPILE_ENVIRONMENT = raw"""
using Pkg
Pkg.activate(ARGS[1]; io=devnull)
started = time_ns()
Pkg.precompile(; io=devnull)
println("BUILD\\t", time_ns() - started)
"""''',
    '''const PRECOMPILE_ENVIRONMENT = raw"""
using Pkg
length(ARGS) == 2 || error("precompile driver expects ENVIRONMENT PACKAGE")
Pkg.activate(ARGS[1]; io=devnull)
started = time_ns()
Pkg.precompile(ARGS[2]; strict=true, io=devnull)
println("BUILD\\t", time_ns() - started)
"""''',
    "target-specific precompile",
)

text = replace_once(
    text,
    '''function layered_depot(first::AbstractString, second::AbstractString)
  return String(first) * string(Sys.iswindows() ? ';' : ':') * String(second)
end''',
    '''function layered_depot(first::AbstractString, second::AbstractString)
  separator = Sys.iswindows() ? ';' : ':'
  return string(String(first), separator, String(second))::String
end''',
    "concrete layered depot",
)

text = replace_once(
    text,
    '''  cmd = julia_command(
    ["-e", PRECOMPILE_ENVIRONMENT, target.environment]; dir=target.checkout
  )''',
    '''  cmd = julia_command(
    ["-e", PRECOMPILE_ENVIRONMENT, target.environment, context.package];
    dir=target.checkout,
  )''',
    "precompile package argument",
)

text = replace_once(
    text,
    '''  cmd = julia_command(args; dir=target.checkout)''',
    '''  cmd = julia_command(args; dir=target.checkout, existing_caches=true)''',
    "existing-only scenario process",
)

marker = '''  allunique(names) || error("PRECOMPILE_BENCHMARKS contains duplicate scenario names")
  return names
end

function parse_sample('''
insertion = '''  allunique(names) || error("PRECOMPILE_BENCHMARKS contains duplicate scenario names")
  return names
end

function matching_scenarios(base::Vector{String}, head::Vector{String})
  isequal(base, head) || error(
    "cold-start workload registry differs under base and head: base=$(repr(base)), head=$(repr(head))"
  )
  return base
end

function parse_sample('''
text = replace_once(text, marker, insertion, "matching workload invariant")

text = replace_once(
    text,
    '''function project_identity(root::AbstractString)
  project = TOML.parsefile(joinpath(root, "Project.toml"))
  name = get(project, "name", nothing)
  uuid = get(project, "uuid", nothing)
  name isa String && uuid isa String ||
    error("$root/Project.toml must define string name and uuid fields")
  return (name=name, uuid=uuid)
end''',
    '''function project_identity(root::AbstractString)
  project = TOML.parsefile(joinpath(root, "Project.toml"))
  raw_name = get(project, "name", nothing)
  raw_uuid = get(project, "uuid", nothing)
  name = raw_name isa String ? raw_name : error(
    "$root/Project.toml must define a string name field"
  )
  uuid = raw_uuid isa String ? raw_uuid : error(
    "$root/Project.toml must define a string uuid field"
  )
  return (name=String(name), uuid=String(uuid))
end''',
    "concrete project identity",
)

text = replace_once(
    text,
    '''function coldstart_file_hash(path::AbstractString)
  try
    command = pipeline(`git hash-object --no-filters $path`; stderr=devnull)
    return strip(read(command, String))
  catch
    return "unknown"
  end
end''',
    '''coldstart_content_hash(content::AbstractString) = bytes2hex(sha256(String(content)))

function coldstart_file_hash(path::AbstractString)
  isfile(path) || error("cold-start provenance file not found: $path")
  return coldstart_content_hash(read(path, String))
end

function coldstart_config_hash(config::ColdStartConfig)
  content = join(
    (
      "scenarios=$(repr(config.scenarios))",
      "builds=$(config.builds)",
      "samples=$(config.samples)",
      "absolute_ns=$(config.absolute_ns)",
      "relative=$(repr(config.relative))",
      "precompile_tasks=$(config.precompile_tasks)",
    ),
    '\n',
  )
  return coldstart_content_hash(content)
end''',
    "SHA-256 provenance",
)

pattern = re.compile(r'''function write_coldstart_results\(.*?\nend\n\nfunction initial_context\(''', re.S)
match = pattern.search(text)
if not match:
    raise SystemExit("write_coldstart_results block not found")
replacement = '''function write_coldstart_results(
  report::ColdStartReport,
  output_dir::AbstractString,
  base::AbstractString,
  head::AbstractString;
  scenario_file::AbstractString,
  scenario_source::AbstractString,
  config_source::AbstractString,
)
  mkpath(output_dir)

  open(joinpath(output_dir, "builds.tsv"), "w") do io
    println(io, "variant\\tbuild\\tprecompile_ns\\tcache_bytes")
    for row in report.builds
      println(
        io, row.variant, '\\t', row.build, '\\t', row.precompile_ns, '\\t', row.cache_bytes
      )
    end
  end

  open(joinpath(output_dir, "samples.tsv"), "w") do io
    println(
      io,
      "variant\\tbuild\\tsample\\tscenario\\timport_ns\\tfirst_ns\\tcompile_ns\\t" *
      "recompile_ns\\ttotal_ns\\twarm_ns\\twarm_compile_ns\\twarm_recompile_ns",
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
          '\\t',
        ),
      )
    end
  end

  write(joinpath(output_dir, "summary.md"), coldstart_markdown(report))
  for environment in report.environments
    write(
      joinpath(output_dir, "$(environment.variant)-consumer-Project.toml"), environment.project
    )
    write(
      joinpath(output_dir, "$(environment.variant)-consumer-Manifest.toml"),
      environment.manifest,
    )
  end

  open(joinpath(output_dir, "metadata.txt"), "w") do io
    println(io, "julia=", VERSION)
    println(io, "cpu_target=", unsafe_string(Base.JLOptions().cpu_target))
    sysimage_target =
      isdefined(Sys, :sysimage_target) ? String(Sys.sysimage_target()) : "unavailable"
    println(io, "sysimage_target=", sysimage_target)
    println(io, "machine=", Sys.MACHINE)
    println(io, "runner_image=", get(ENV, "ImageVersion", "unknown"))
    println(io, "base_commit=", full_commit(base))
    println(io, "head_commit=", full_commit(head))
    println(io, "config_source=", config_source)
    println(io, "config_hash=", coldstart_config_hash(report.config))
    println(io, "scenario_source=", scenario_source)
    println(io, "scenario_path=", report.config.scenarios)
    println(io, "scenario_hash=", coldstart_file_hash(scenario_file))
    println(io, "builds=", report.config.builds)
    println(io, "samples=", report.config.samples)
    println(io, "absolute_ns=", report.config.absolute_ns)
    println(io, "relative=", report.config.relative)
    println(io, "precompile_tasks=", report.config.precompile_tasks)
    for environment in sort(report.environments; by=entry -> entry.variant)
      println(
        io,
        environment.variant,
        "_consumer_project_sha256=",
        coldstart_content_hash(environment.project),
      )
      println(
        io,
        environment.variant,
        "_consumer_manifest_sha256=",
        coldstart_content_hash(environment.manifest),
      )
    end
  end
  return String(output_dir)
end

function initial_context('''
text = text[:match.start()] + replacement + text[match.end():]

marker = '''function run_context(context::ColdStartContext, scenarios::Vector{String})
  return ColdStartContext(
    context.package, context.scenario_file, context.config, context.seed_depot, scenarios
  )
end

function warmup_target'''
insertion = '''function run_context(context::ColdStartContext, scenarios::Vector{String})
  return ColdStartContext(
    context.package, context.scenario_file, context.config, context.seed_depot, scenarios
  )
end

function coldstart_environment(target::ColdStartTarget)
  project_path = joinpath(target.environment, "Project.toml")
  manifest_path = joinpath(target.environment, "Manifest.toml")
  isfile(project_path) || error("cold-start consumer Project missing: $project_path")
  isfile(manifest_path) || error("cold-start consumer Manifest missing: $manifest_path")
  return ColdStartEnvironment(
    target.variant, read(project_path, String), read(manifest_path, String)
  )
end

function warmup_target'''
text = replace_once(text, marker, insertion, "environment snapshot helper")

text = replace_once(
    text,
    '''  setup = initial_context(package, scenario_file, config, seed_depot)
  discovery_depot = joinpath(temporary, "discovery-depot")
  mkpath(discovery_depot)
  scenarios = discover_scenarios(
    head_target, setup, layered_depot(discovery_depot, seed_depot)
  )
  context = run_context(setup, scenarios)''',
    '''  setup = initial_context(package, scenario_file, config, seed_depot)
  base_discovery_depot = joinpath(temporary, "discovery-base")
  head_discovery_depot = joinpath(temporary, "discovery-head")
  mkpath(base_discovery_depot)
  mkpath(head_discovery_depot)
  base_scenarios = discover_scenarios(
    base_target, setup, layered_depot(base_discovery_depot, seed_depot)
  )
  head_scenarios = discover_scenarios(
    head_target, setup, layered_depot(head_discovery_depot, seed_depot)
  )
  scenarios = matching_scenarios(base_scenarios, head_scenarios)
  context = run_context(setup, scenarios)''',
    "dual scenario discovery",
)

text = replace_once(
    text,
    '''  return scenarios, builds, samples
end''',
    '''  environments = ColdStartEnvironment[coldstart_environment(target) for target in targets]
  return scenarios, builds, samples, environments
end''',
    "environment experiment return",
)

text = replace_once(
    text,
    '''scenario sample runs in a fresh Julia process. A relative scenario registry is
frozen to the base revision; head is used only when the base has no registry yet.

Only target-package precompile time''',
    '''scenario sample runs in a fresh Julia process. The complete comparison protocol
is frozen to the base revision: configuration and relative scenario registry come
from base whenever present, with head used only for first-time bootstrap. Base and
head must discover the same ordered scenario names before any timing is accepted.

Only target-package precompile time''',
    "coldstart compare documentation",
)

text = replace_once(
    text,
    '''  base_identity = project_identity(base_path)
  head_identity = project_identity(head_path)
  base_identity == head_identity ||
    error("cold-start checkouts name different packages: $base_identity != $head_identity")
  package = head_identity.name

  config_dir =
    isabspath(ratchet_dir) ? String(ratchet_dir) : joinpath(head_path, ratchet_dir)
  config = coldstart_config(head_path; dir=config_dir)
  scenario = coldstart_scenario_file(base_path, head_path, config)

  scenarios, builds, samples = mktempdir() do temporary
    return run_coldstart_experiment(
      base_path, head_path, package, scenario.file, config, temporary
    )
  end

  verdicts = coldstart_verdicts(config, scenarios, builds, samples)
  report = ColdStartReport(config, scenarios, builds, samples, verdicts)
  isempty(output_dir) || write_coldstart_results(
    report,
    output_dir,
    base_path,
    head_path;
    scenario_file=scenario.file,
    scenario_source=scenario.source,
  )''',
    '''  base_identity = project_identity(base_path)
  head_identity = project_identity(head_path)
  isequal(base_identity, head_identity) ||
    error("cold-start checkouts name different packages: $base_identity != $head_identity")
  package = head_identity.name

  selection = coldstart_config_selection(base_path, head_path, ratchet_dir)
  config = selection.config
  scenario = coldstart_scenario_file(base_path, head_path, config)

  scenarios, builds, samples, environments = mktempdir() do temporary
    return run_coldstart_experiment(
      base_path, head_path, package, scenario.file, config, temporary
    )
  end

  verdicts = coldstart_verdicts(config, scenarios, builds, samples)
  report = ColdStartReport(config, scenarios, builds, samples, verdicts, environments)
  isempty(output_dir) || write_coldstart_results(
    report,
    output_dir,
    base_path,
    head_path;
    scenario_file=scenario.file,
    scenario_source=scenario.source,
    config_source=selection.source,
  )''',
    "frozen protocol compare",
)
path.write_text(text)

test_path = Path("test/coldstart_metric.jl")
tests = test_path.read_text()
tests = replace_once(
    tests,
    '''      write(joinpath(dir, "rulings.toml"), "[coldstart]\\nbuilds = 0\\n")
      @test_throws ErrorException CodeRatchet.coldstart_config(root; dir)
      write(joinpath(dir, "rulings.toml"), "[coldstart]\\nrelative = 1.0\\n")
      @test_throws ErrorException CodeRatchet.coldstart_config(root; dir)''',
    '''      write(joinpath(dir, "rulings.toml"), "[coldstart]\\nbuilds = 0\\n")
      @test_throws ErrorException CodeRatchet.coldstart_config(root; dir)
      write(joinpath(dir, "rulings.toml"), "[coldstart]\\nbuilds = \\\"many\\\"\\n")
      @test_throws ErrorException CodeRatchet.coldstart_config(root; dir)
      write(joinpath(dir, "rulings.toml"), "[coldstart]\\nabsolute_ms = \\\"slow\\\"\\n")
      @test_throws ErrorException CodeRatchet.coldstart_config(root; dir)
      write(joinpath(dir, "rulings.toml"), "[coldstart]\\nabsolute_ms = -1\\n")
      @test_throws ErrorException CodeRatchet.coldstart_config(root; dir)
      write(joinpath(dir, "rulings.toml"), "[coldstart]\\nrelative = \\\"large\\\"\\n")
      @test_throws ErrorException CodeRatchet.coldstart_config(root; dir)
      write(joinpath(dir, "rulings.toml"), "[coldstart]\\nrelative = 1.0\\n")
      @test_throws ErrorException CodeRatchet.coldstart_config(root; dir)''',
    "configuration error coverage",
)

marker = '''  @testset "scenario registry is frozen to base after bootstrap" begin'''
addition = '''  @testset "configuration is frozen to base after bootstrap" begin
    mktempdir() do root
      base = joinpath(root, "base")
      head = joinpath(root, "head")
      base_dir = joinpath(base, "code_ratchet")
      head_dir = joinpath(head, "code_ratchet")
      mkpath(base_dir)
      mkpath(head_dir)
      write(joinpath(base_dir, "rulings.toml"), "[scope]\\nmeasure = [\\\"src/\\\"]\\n")
      write(
        joinpath(head_dir, "rulings.toml"),
        "[coldstart]\\nbuilds = 3\\nsamples = 1\\n",
      )
      selection = CodeRatchet.coldstart_config_selection(base, head, "code_ratchet")
      @test selection.source == "head-bootstrap"
      @test selection.config.builds == 3

      write(
        joinpath(base_dir, "rulings.toml"),
        "[coldstart]\\nbuilds = 2\\nsamples = 1\\n",
      )
      selection = CodeRatchet.coldstart_config_selection(base, head, "code_ratchet")
      @test selection.source == "base"
      @test selection.config.builds == 2

      selection = CodeRatchet.coldstart_config_selection(base, head, head_dir)
      @test selection.source == "absolute"
      @test selection.config.builds == 3
    end
  end

  @testset "scenario registry is frozen to base after bootstrap" begin'''
tests = replace_once(tests, marker, addition, "configuration source tests")

tests = replace_once(
    tests,
    '''      scenario = CodeRatchet.coldstart_scenario_file(base, head, config)
      @test scenario.source == "base"
      @test scenario.file == joinpath(base, "scenarios.jl")
    end
  end''',
    '''      scenario = CodeRatchet.coldstart_scenario_file(base, head, config)
      @test scenario.source == "base"
      @test scenario.file == joinpath(base, "scenarios.jl")

      absolute = joinpath(root, "absolute-scenarios.jl")
      write(absolute, "absolute\\n")
      absolute_config = CodeRatchet.ColdStartConfig(absolute, 1, 1, 0, 0.0, 1)
      scenario = CodeRatchet.coldstart_scenario_file(base, head, absolute_config)
      @test scenario.source == "absolute"
      @test scenario.file == absolute
      missing_config = CodeRatchet.ColdStartConfig(joinpath(root, "missing.jl"), 1, 1, 0, 0.0, 1)
      @test_throws ErrorException CodeRatchet.coldstart_scenario_file(base, head, missing_config)
    end
  end

  @testset "base and head must expose the same ordered workload registry" begin
    @test CodeRatchet.matching_scenarios(["a", "b"], ["a", "b"]) == ["a", "b"]
    @test_throws ErrorException CodeRatchet.matching_scenarios(["a"], ["b"])
    @test_throws ErrorException CodeRatchet.matching_scenarios(["a", "b"], ["b", "a"])
  end''',
    "absolute scenario and matching registry tests",
)

tests = replace_once(
    tests,
    '''    @test !occursin("--code-coverage", rendered)
    @test !occursin("--check-bounds", rendered)''',
    '''    @test !occursin("--code-coverage", rendered)
    @test !occursin("--check-bounds", rendered)
    cached = CodeRatchet.julia_command(["--version"]; dir=pwd(), existing_caches=true)
    cached_rendered = string(cached)
    @test occursin("--compiled-modules=existing", cached_rendered)
    @test occursin("--pkgimages=existing", cached_rendered)
    @test occursin("Pkg.precompile(ARGS[2]; strict=true", CodeRatchet.PRECOMPILE_ENVIRONMENT)''',
    "cache boundary tests",
)

tests = replace_once(
    tests,
    '''      CodeRatchet.write_coldstart_results(
        report, output, pwd(), pwd(); scenario_file, scenario_source="base"
      )''',
    '''      CodeRatchet.write_coldstart_results(
        report,
        output,
        pwd(),
        pwd();
        scenario_file,
        scenario_source="base",
        config_source="base",
      )''',
    "result provenance call",
)

tests = replace_once(
    tests,
    '''      @test occursin("runner_image=", metadata)
      @test occursin("scenario_source=base", metadata)
      @test occursin("scenario_path=scenarios.jl", metadata)
      @test occursin("scenario_hash=", metadata)
      @test !occursin("scenario_hash=unknown", metadata)''',
    '''      @test occursin("runner_image=", metadata)
      @test occursin("sysimage_target=", metadata)
      @test occursin("config_source=base", metadata)
      @test occursin("config_hash=", metadata)
      @test occursin("scenario_source=base", metadata)
      @test occursin("scenario_path=scenarios.jl", metadata)
      hash_line = only(filter(line -> startswith(line, "scenario_hash="), split(metadata, '\\n')))
      @test length(split(hash_line, "="; limit=2)[2]) == 64''',
    "result provenance assertions",
)

tests = replace_once(
    tests,
    '''        "--ratchet-dir",
        ratchet,
        "--output",''',
    '''        "--ratchet-dir",
        "code_ratchet",
        "--output",''',
    "relative bootstrap ratchet dir",
)

tests = replace_once(
    tests,
    '''      @test isfile(joinpath(output, "summary.md"))
      @test countlines(joinpath(output, "builds.tsv")) == 3''',
    '''      @test isfile(joinpath(output, "summary.md"))
      @test isfile(joinpath(output, "base-consumer-Project.toml"))
      @test isfile(joinpath(output, "base-consumer-Manifest.toml"))
      @test isfile(joinpath(output, "head-consumer-Project.toml"))
      @test isfile(joinpath(output, "head-consumer-Manifest.toml"))
      @test countlines(joinpath(output, "builds.tsv")) == 3''',
    "consumer environment artifacts",
)

tests = replace_once(
    tests,
    '''      @test occursin("scenario_source=head-bootstrap", metadata)
      @test !occursin("scenario_hash=unknown", metadata)''',
    '''      @test occursin("config_source=head-bootstrap", metadata)
      @test occursin("scenario_source=head-bootstrap", metadata)
      @test occursin("base_consumer_manifest_sha256=", metadata)
      @test occursin("head_consumer_manifest_sha256=", metadata)''',
    "bootstrap metadata assertions",
)

tests = replace_once(
    tests,
    '''    @test CodeRatchet.coldstart_main(["compare", "--wat", "value"]) == 2
  end''',
    '''    @test CodeRatchet.coldstart_main(["compare", "--wat", "value"]) == 2
    missing = joinpath(pwd(), "definitely-missing-coldstart-checkout")
    @test CodeRatchet.coldstart_main(["compare", "--base", missing]) == 1
  end''',
    "CLI report failure coverage",
)
test_path.write_text(tests)

readme_path = Path("README.md")
readme = readme_path.read_text()
readme = readme.replace(
    "Six metrics today, one comparison rule:",
    "Seven persistent metrics today, one comparison rule:",
    1,
)
section = re.compile(r"### Cold-start regression tracking\n.*?\n### By hand\n", re.S)
match = section.search(readme)
if not match:
    raise SystemExit("README cold-start section not found")
new_section = '''### Cold-start regression tracking

Cold-start is a separate paired experiment rather than a persistent metric.
It compares exact base and head revisions on the same runner, with independent
target-package cache builds and fresh Julia processes for each scenario sample.
Only package precompile time and total time-to-first-execution gate; import,
compilation/recompilation, warm latency and cache bytes remain diagnostic context.

The **complete comparison protocol is frozen to the base revision**. If base
already has a `[coldstart]` block, its scenario path, build/sample counts,
materiality thresholds and precompile worker count judge both revisions. A head
configuration is used only while bootstrapping a repository that had no
cold-start configuration before the PR. The same rule applies to the relative
scenario registry. Base and head must also discover the same ordered scenario
names; otherwise there is no paired experiment to compare and the job fails.

Put representative zero-argument workloads in
`benchmark/precompile/scenarios.jl` as an ordered named tuple named
`PRECOMPILE_BENCHMARKS`:

```julia
exercise_api() = check(MyPackage.answer() == 42, "unexpected answer")

const PRECOMPILE_BENCHMARKS = (
    exercise_api = exercise_api,
)
```

```toml
[coldstart]
scenarios = "benchmark/precompile/scenarios.jl"
builds = 2
samples = 5
absolute_ms = 50
relative = 0.05
precompile_tasks = 1
```

Each measured build explicitly precompiles the target package. Scenario
processes then run with `--compiled-modules=existing --pkgimages=existing`, so
that phase may consume the package caches just built but cannot silently create
new ones. Runtime JIT work still contributes to first-use latency. The result
artifact includes the exact base/head consumer Project and Manifest files,
SHA-256 workload/config/environment identities, Julia runtime/system-image
identity and both commit SHAs.

Use the paired workflow separately from the persistent ratchet job and pin the
CodeRatchet revision:

```yaml
jobs:
  coldstart:
    uses: oameye/CodeRatchet.jl/.github/workflows/coldstart.yml@<CODE_RATCHET_SHA>
```

The same experiment can be run locally against two checkouts:

```sh
julia --project=code_ratchet \\
  -e 'using CodeRatchet; exit(CodeRatchet.coldstart_main())' \\
  compare --base /path/to/base --head /path/to/head \\
  --output coldstart-results
```

Timing is intentionally not written into the normal CodeRatchet baseline:
runner noise is handled by same-run base/head comparison, alternating build
order, repeated fresh processes and explicit materiality floors instead.

### By hand
'''
readme = readme[: match.start()] + new_section + readme[match.end() :]
readme_path.write_text(readme)
