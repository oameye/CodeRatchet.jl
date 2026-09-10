using Test
using CodeRatchet

function sample(variant, build, sample_id, scenario, total_ns; compile_ns=10_000_000)
  return CodeRatchet.ColdStartSample(
    variant,
    build,
    sample_id,
    scenario,
    20_000_000,
    total_ns - 20_000_000,
    compile_ns,
    0,
    total_ns,
    1_000_000,
    0,
    0,
  )
end

@testset "cold-start comparison" begin
  @testset "configuration has conservative defaults and validates overrides" begin
    mktempdir() do root
      dir = joinpath(root, "code_ratchet")
      mkpath(dir)
      write(joinpath(dir, "rulings.toml"), "[scope]\nmeasure = [\"src/\"]\n")
      config = CodeRatchet.coldstart_config(root; dir)
      @test config.scenarios == "benchmark/precompile/scenarios.jl"
      @test config.builds == 2
      @test config.samples == 5
      @test config.absolute_ns == 50_000_000
      @test config.relative == 0.05
      @test config.precompile_tasks == 1

      write(
        joinpath(dir, "rulings.toml"),
        """
        [coldstart]
        scenarios = "bench/scenarios.jl"
        builds = 3
        samples = 7
        absolute_ms = 12.5
        relative = 0.08
        precompile_tasks = 2
        """,
      )
      config = CodeRatchet.coldstart_config(root; dir)
      @test config.scenarios == "bench/scenarios.jl"
      @test config.builds == 3
      @test config.samples == 7
      @test config.absolute_ns == 12_500_000
      @test config.relative == 0.08
      @test config.precompile_tasks == 2

      write(joinpath(dir, "rulings.toml"), "[coldstart]\nbuilds = 0\n")
      @test_throws ErrorException CodeRatchet.coldstart_config(root; dir)
      write(joinpath(dir, "rulings.toml"), "[coldstart]\nbuilds = \"many\"\n")
      @test_throws ErrorException CodeRatchet.coldstart_config(root; dir)
      write(joinpath(dir, "rulings.toml"), "[coldstart]\nabsolute_ms = \"slow\"\n")
      @test_throws ErrorException CodeRatchet.coldstart_config(root; dir)
      write(joinpath(dir, "rulings.toml"), "[coldstart]\nabsolute_ms = -1\n")
      @test_throws ErrorException CodeRatchet.coldstart_config(root; dir)
      write(joinpath(dir, "rulings.toml"), "[coldstart]\nrelative = \"large\"\n")
      @test_throws ErrorException CodeRatchet.coldstart_config(root; dir)
      write(joinpath(dir, "rulings.toml"), "[coldstart]\nrelative = 1.0\n")
      @test_throws ErrorException CodeRatchet.coldstart_config(root; dir)
    end
  end

  @testset "configuration is frozen to base after bootstrap" begin
    mktempdir() do root
      base = joinpath(root, "base")
      head = joinpath(root, "head")
      base_dir = joinpath(base, "code_ratchet")
      head_dir = joinpath(head, "code_ratchet")
      mkpath(base_dir)
      mkpath(head_dir)
      write(joinpath(base_dir, "rulings.toml"), "[scope]\nmeasure = [\"src/\"]\n")
      write(joinpath(head_dir, "rulings.toml"), "[coldstart]\nbuilds = 3\nsamples = 1\n")
      selection = CodeRatchet.coldstart_config_selection(base, head, "code_ratchet")
      @test selection.source == "head-bootstrap"
      @test selection.config.builds == 3

      write(joinpath(base_dir, "rulings.toml"), "[coldstart]\nbuilds = 2\nsamples = 1\n")
      selection = CodeRatchet.coldstart_config_selection(base, head, "code_ratchet")
      @test selection.source == "base"
      @test selection.config.builds == 2

      selection = CodeRatchet.coldstart_config_selection(base, head, head_dir)
      @test selection.source == "absolute"
      @test selection.config.builds == 3
    end
  end

  @testset "scenario registry is frozen to base after bootstrap" begin
    mktempdir() do root
      base = joinpath(root, "base")
      head = joinpath(root, "head")
      mkpath(base)
      mkpath(head)
      config = CodeRatchet.ColdStartConfig("scenarios.jl", 1, 1, 0, 0.0, 1)

      write(
        joinpath(head, "scenarios.jl"),
        "head
",
      )
      scenario = CodeRatchet.coldstart_scenario_file(base, head, config)
      @test scenario.source == "head-bootstrap"
      @test scenario.file == joinpath(head, "scenarios.jl")

      write(
        joinpath(base, "scenarios.jl"),
        "base
",
      )
      scenario = CodeRatchet.coldstart_scenario_file(base, head, config)
      @test scenario.source == "base"
      @test scenario.file == joinpath(base, "scenarios.jl")

      absolute = joinpath(root, "absolute-scenarios.jl")
      write(absolute, "absolute\n")
      absolute_config = CodeRatchet.ColdStartConfig(absolute, 1, 1, 0, 0.0, 1)
      scenario = CodeRatchet.coldstart_scenario_file(base, head, absolute_config)
      @test scenario.source == "absolute"
      @test scenario.file == absolute
      missing_config = CodeRatchet.ColdStartConfig(
        joinpath(root, "missing.jl"), 1, 1, 0, 0.0, 1
      )
      @test_throws ErrorException CodeRatchet.coldstart_scenario_file(
        base, head, missing_config
      )
    end
  end

  @testset "base and head must expose the same ordered workload registry" begin
    @test CodeRatchet.matching_scenarios(["a", "b"], ["a", "b"]) == ["a", "b"]
    @test_throws ErrorException CodeRatchet.matching_scenarios(["a"], ["b"])
    @test_throws ErrorException CodeRatchet.matching_scenarios(["a", "b"], ["b", "a"])
  end

  @testset "median and materiality are exact" begin
    @test CodeRatchet.median_int([9, 1, 5]) == 5
    @test CodeRatchet.median_int([1, 3, 7, 9]) == 5
    @test_throws ErrorException CodeRatchet.median_int(Int[])

    config = CodeRatchet.ColdStartConfig("scenarios.jl", 2, 3, 50_000_000, 0.05, 1)
    @test CodeRatchet.material_threshold(config, 200_000_000) == 50_000_000
    @test CodeRatchet.material_threshold(config, 2_000_000_000) == 100_000_000
    @test CodeRatchet.material_regression(config, 1_000_000_000, 1_050_000_000)
    @test !CodeRatchet.material_regression(config, 1_000_000_000, 1_049_999_999)
  end

  @testset "a noisy signal fails only when every independent build regresses" begin
    config = CodeRatchet.ColdStartConfig("scenarios.jl", 2, 3, 50_000_000, 0.05, 1)
    builds = [
      CodeRatchet.ColdStartBuild("base", 1, 1_000_000_000, 100),
      CodeRatchet.ColdStartBuild("head", 1, 1_100_000_000, 110),
      CodeRatchet.ColdStartBuild("base", 2, 1_000_000_000, 100),
      CodeRatchet.ColdStartBuild("head", 2, 1_020_000_000, 110),
    ]
    samples = CodeRatchet.ColdStartSample[]
    for build in 1:2, sample_id in 1:3
      push!(samples, sample("base", build, sample_id, "solve", 500_000_000))
      push!(samples, sample("head", build, sample_id, "solve", 600_000_000))
    end

    verdicts = CodeRatchet.coldstart_verdicts(config, ["solve"], builds, samples)
    precompile, solve = verdicts
    @test precompile.regressed_builds == 1
    @test !precompile.failed
    @test solve.regressed_builds == 2
    @test solve.failed

    report = CodeRatchet.ColdStartReport(config, ["solve"], builds, samples, verdicts)
    @test !CodeRatchet.ok(report)
    @test occursin("CodeRatchet coldstart: FAIL", sprint(show, report))
    markdown = CodeRatchet.coldstart_markdown(report)
    @test occursin("| precompile |", markdown)
    @test occursin("| solve |", markdown)
    @test occursin("FAIL", markdown)
  end

  @testset "compiler decomposition is context, not an independent noisy gate" begin
    config = CodeRatchet.ColdStartConfig("scenarios.jl", 1, 1, 50_000_000, 0.05, 1)
    builds = [
      CodeRatchet.ColdStartBuild("base", 1, 100_000_000, 100),
      CodeRatchet.ColdStartBuild("head", 1, 100_000_000, 200),
    ]
    samples = [
      sample("base", 1, 1, "solve", 500_000_000; compile_ns=1_000_000),
      sample("head", 1, 1, "solve", 500_000_000; compile_ns=400_000_000),
    ]
    verdicts = CodeRatchet.coldstart_verdicts(config, ["solve"], builds, samples)
    report = CodeRatchet.ColdStartReport(config, ["solve"], builds, samples, verdicts)
    @test CodeRatchet.ok(report)
    @test all(!verdict.failed for verdict in verdicts)
  end

  @testset "driver rows parse into integer nanosecond observations" begin
    output = "noise\nRESULT\tsolve\t10\t20\t5\t1\t30\t2\t0\t0\n"
    target = CodeRatchet.ColdStartTarget("head", pwd(), pwd())
    parsed = CodeRatchet.parse_sample(output, target, 2, 3, "solve")
    @test parsed.variant == "head"
    @test parsed.build == 2
    @test parsed.sample == 3
    @test parsed.total_ns == 30
    @test parsed.recompile_ns == 1
    @test_throws ErrorException CodeRatchet.parse_sample(output, target, 2, 3, "other")
  end

  @testset "child Julia commands do not inherit parent instrumentation" begin
    cmd = CodeRatchet.julia_command(["--version"]; dir=pwd())
    rendered = string(cmd)
    @test occursin("--startup-file=no", rendered)
    @test occursin("--history-file=no", rendered)
    @test !occursin("--code-coverage", rendered)
    @test !occursin("--check-bounds", rendered)
    cached = CodeRatchet.julia_command(["--version"]; dir=pwd(), existing_caches=true)
    cached_rendered = string(cached)
    @test occursin("--compiled-modules=existing", cached_rendered)
    @test occursin("--pkgimages=existing", cached_rendered)
    @test occursin(
      "Pkg.precompile(ARGS[2]; strict=true", CodeRatchet.PRECOMPILE_ENVIRONMENT
    )
  end

  @testset "cache helpers measure and remove only the target package" begin
    mktempdir() do depot
      version_dir = "v$(VERSION.major).$(VERSION.minor)"
      target = joinpath(depot, "compiled", version_dir, "Tiny")
      other = joinpath(depot, "compiled", version_dir, "Other")
      mkpath(target)
      mkpath(other)
      write(joinpath(target, "a.ji"), "12345")
      write(joinpath(other, "b.ji"), "123456789")
      @test CodeRatchet.package_cache_bytes(depot, "Tiny") == 5
      CodeRatchet.remove_package_cache(depot, "Tiny")
      @test CodeRatchet.package_cache_bytes(depot, "Tiny") == 0
      @test isfile(joinpath(other, "b.ji"))
    end
  end

  @testset "results carry runtime and scenario provenance" begin
    config = CodeRatchet.ColdStartConfig("scenarios.jl", 1, 1, 50_000_000, 0.05, 1)
    builds = [
      CodeRatchet.ColdStartBuild("base", 1, 100, 10),
      CodeRatchet.ColdStartBuild("head", 1, 90, 11),
    ]
    samples = [sample("base", 1, 1, "solve", 100), sample("head", 1, 1, "solve", 90)]
    verdicts = CodeRatchet.coldstart_verdicts(config, ["solve"], builds, samples)
    report = CodeRatchet.ColdStartReport(config, ["solve"], builds, samples, verdicts)
    mktempdir() do output
      scenario_file = joinpath(output, "scenarios.jl")
      write(
        scenario_file,
        "nothing
",
      )
      CodeRatchet.write_coldstart_results(
        report,
        output,
        pwd(),
        pwd();
        scenario_file,
        scenario_source="base",
        config_source="base",
      )
      @test isfile(joinpath(output, "builds.tsv"))
      @test isfile(joinpath(output, "samples.tsv"))
      @test isfile(joinpath(output, "summary.md"))
      metadata = read(joinpath(output, "metadata.txt"), String)
      @test occursin("julia=$(VERSION)", metadata)
      @test occursin("cpu_target=", metadata)
      @test occursin("runner_image=", metadata)
      @test occursin("sysimage_target=", metadata)
      @test occursin("config_source=base", metadata)
      @test occursin("config_hash=", metadata)
      @test occursin("scenario_source=base", metadata)
      @test occursin("scenario_path=scenarios.jl", metadata)
      hash_line = only(
        filter(line -> startswith(line, "scenario_hash="), split(metadata, '\n'))
      )
      @test length(split(hash_line, "="; limit=2)[2]) == 64
    end
  end

  @testset "CLI option parsing is complete and rejects malformed input" begin
    args = [
      "compare",
      "--base",
      "/base",
      "--head",
      "/head",
      "--ratchet-dir",
      "/ratchet",
      "--output",
      "/output",
    ]
    options = CodeRatchet.parse_coldstart_options(args)
    @test options.base == "/base"
    @test options.head == "/head"
    @test options.ratchet_dir == "/ratchet"
    @test options.output == "/output"
    @test_throws ArgumentError CodeRatchet.parse_coldstart_options(["compare"])
    @test_throws ArgumentError CodeRatchet.parse_coldstart_options(["compare", "--base"])
    @test_throws ArgumentError CodeRatchet.parse_coldstart_options([
      "compare", "--wat", "value", "--base", "/base"
    ])
  end

  @testset "the full CLI experiment works on a dependency-free local package" begin
    mktempdir() do root
      base = joinpath(root, "base")
      head = joinpath(root, "head")
      for checkout in (base, head)
        mkpath(joinpath(checkout, "src"))
        write(
          joinpath(checkout, "Project.toml"),
          """
          name = "TinyColdStart"
          uuid = "11111111-1111-1111-1111-111111111111"
          version = "0.1.0"
          """,
        )
        write(
          joinpath(checkout, "src", "TinyColdStart.jl"),
          "module TinyColdStart\nf(x) = x + 1\nend\n",
        )
      end

      ratchet = joinpath(head, "code_ratchet")
      scenarios = joinpath(head, "benchmark", "precompile")
      output = joinpath(root, "results")
      mkpath(ratchet)
      mkpath(scenarios)
      write(
        joinpath(ratchet, "rulings.toml"),
        """
        [coldstart]
        scenarios = "benchmark/precompile/scenarios.jl"
        builds = 1
        samples = 1
        absolute_ms = 100000
        relative = 0.0
        precompile_tasks = 1
        """,
      )
      write(
        joinpath(scenarios, "scenarios.jl"),
        """
        function smoke()
          value = TinyColdStart.f(1)
          check(value == 2, "TinyColdStart returned the wrong value")
          return value
        end
        const PRECOMPILE_BENCHMARKS = (smoke=smoke,)
        """,
      )

      exitcode = CodeRatchet.coldstart_main([
        "compare",
        "--base",
        base,
        "--head",
        head,
        "--ratchet-dir",
        "code_ratchet",
        "--output",
        output,
      ])
      @test exitcode == 0
      @test isfile(joinpath(output, "builds.tsv"))
      @test isfile(joinpath(output, "samples.tsv"))
      @test isfile(joinpath(output, "summary.md"))
      @test isfile(joinpath(output, "base-consumer-Project.toml"))
      @test isfile(joinpath(output, "base-consumer-Manifest.toml"))
      @test isfile(joinpath(output, "head-consumer-Project.toml"))
      @test isfile(joinpath(output, "head-consumer-Manifest.toml"))
      @test countlines(joinpath(output, "builds.tsv")) == 3
      @test countlines(joinpath(output, "samples.tsv")) == 3
      @test occursin("| smoke |", read(joinpath(output, "summary.md"), String))
      metadata = read(joinpath(output, "metadata.txt"), String)
      @test occursin("config_source=head-bootstrap", metadata)
      @test occursin("scenario_source=head-bootstrap", metadata)
      @test occursin("base_consumer_manifest_sha256=", metadata)
      @test occursin("head_consumer_manifest_sha256=", metadata)
    end
  end

  @testset "the command surface refuses incomplete invocations" begin
    @test CodeRatchet.coldstart_main(String[]) == 2
    @test CodeRatchet.coldstart_main(["nope"]) == 2
    @test CodeRatchet.coldstart_main(["compare"]) == 2
    @test CodeRatchet.coldstart_main(["compare", "--base"]) == 2
    @test CodeRatchet.coldstart_main(["compare", "--wat", "value"]) == 2
    missing = joinpath(pwd(), "definitely-missing-coldstart-checkout")
    @test CodeRatchet.coldstart_main(["compare", "--base", missing]) == 1
  end
end
