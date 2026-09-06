using Test
using CodeRatchet
using CodeRatchet:
  Complexity,
  Coverage,
  Row,
  Violation,
  ratchet,
  pair_renames,
  parse_lcov,
  parse_failures,
  unscoped_files,
  read_rulings,
  exempt_counts,
  stale_exemptions,
  candidates,
  write_baseline,
  read_baseline,
  tracked_julia_files,
  metric_name,
  binding,
  row_numbers,
  measure,
  check,
  refresh,
  ok

# A metric with no measurement behind it, so the ratchet can be tested on its
# own. Two numbers, one binding, which is the shape every real metric has.
struct Fake <: CodeRatchet.Metric end
CodeRatchet.metric_name(::Fake) = "fake"
CodeRatchet.binding(::Fake) = ("bind",)
CodeRatchet.row_numbers(::Fake) = ("bind", "context")

fake(bind, context) = Row(Dict("bind" => bind, "context" => context))

@testset "CodeRatchet" begin
  @testset "the ratchet" begin
    base = Dict("a.jl" => fake(5, 50))

    @testset "steady is quiet" begin
      v, _, _, _ = ratchet(Fake(), Dict("a.jl" => fake(5, 50)), base)
      @test isempty(v)
    end

    @testset "a fall is quiet" begin
      v, _, _, _ = ratchet(Fake(), Dict("a.jl" => fake(4, 50)), base)
      @test isempty(v)
    end

    @testset "a rise is a violation, with both values" begin
      v, _, _, _ = ratchet(Fake(), Dict("a.jl" => fake(6, 50)), base)
      @test length(v) == 1
      @test v[1].path == "a.jl" && v[1].key == "bind"
      @test v[1].from == 5 && v[1].to == 6
    end

    @testset "a non-binding number may rise freely" begin
      v, _, _, _ = ratchet(Fake(), Dict("a.jl" => fake(5, 999)), base)
      @test isempty(v)
    end

    @testset "a new file enters freely when the metric is not strict" begin
      v, new, _, _ = ratchet(
        Fake(), Dict("a.jl" => fake(5, 50), "b.jl" => fake(9, 9)), base
      )
      @test isempty(v)
      @test new == ["b.jl"]
    end

    @testset "a deleted file is stale, not a violation" begin
      v, _, _, stale = ratchet(Fake(), Dict{String,Row}(), base)
      @test isempty(v)
      @test stale == ["a.jl"]
    end
  end

  @testset "rename pairing" begin
    @testset "an unambiguous rename carries its history" begin
      base = Dict("old.jl" => fake(7, 70))
      cur = Dict("new.jl" => fake(7, 70))
      v, new, renames, stale = ratchet(Fake(), cur, base)
      @test renames == Dict("new.jl" => "old.jl")
      @test isempty(v) && isempty(new) && isempty(stale)
    end

    @testset "a rename plus a rise is still caught" begin
      base = Dict("old.jl" => fake(7, 70))
      # numbers differ, so this is not a rename: it enters as a new file
      v, new, renames, _ = ratchet(Fake(), Dict("new.jl" => fake(8, 70)), base)
      @test isempty(renames)
      @test new == ["new.jl"]
      @test isempty(v)
    end

    @testset "pairing uses every number, not just the binding one" begin
      # Same binding value, different context: not the same file.
      base = Dict("old.jl" => fake(7, 70))
      _, new, renames, _ = ratchet(Fake(), Dict("new.jl" => fake(7, 71)), base)
      @test isempty(renames)
      @test new == ["new.jl"]
    end

    @testset "an ambiguous pairing is refused" begin
      base = Dict("old1.jl" => fake(7, 70), "old2.jl" => fake(7, 70))
      cur = Dict("new1.jl" => fake(7, 70), "new2.jl" => fake(7, 70))
      _, _, renames, _ = ratchet(Fake(), cur, base)
      @test isempty(renames)
    end
  end

  @testset "strict_new" begin
    @test CodeRatchet.strict_new(Coverage())
    @test !CodeRatchet.strict_new(Complexity())
  end

  @testset "lcov parsing" begin
    root = mktempdir()
    write(
      joinpath(root, "lcov.info"),
      """
SF:$(joinpath(root, "src/a.jl"))
DA:1,3
DA:2,0
DA:3,0
end_of_record
SF:$(joinpath(root, "src/b.jl"))
DA:1,1
end_of_record
""",
    )
    got = parse_lcov(joinpath(root, "lcov.info"), root)
    @test got["src/a.jl"] == (3, 2)
    @test got["src/b.jl"] == (1, 0)

    @testset "records for one file accumulate across workers" begin
      write(
        joinpath(root, "split.info"),
        """
SF:$(joinpath(root, "src/a.jl"))
DA:1,0
DA:2,0
end_of_record
SF:$(joinpath(root, "src/a.jl"))
DA:1,4
DA:2,0
end_of_record
""",
      )
      got2 = parse_lcov(joinpath(root, "split.info"), root)
      # line 1 was hit by the second worker, so only line 2 misses
      @test got2["src/a.jl"] == (2, 1)
    end

    @testset "a missing tracefile is an error, not a silent zero" begin
      @test_throws ErrorException parse_lcov(joinpath(root, "nope.info"), root)
    end
  end

  @testset "parseability is checked separately" begin
    root = mktempdir()
    mkpath(joinpath(root, "src"))
    write(joinpath(root, "src/good.jl"), "f(x) = x + 1\n")
    write(joinpath(root, "src/bad.jl"), "function g(y\n  return y\nend\n")
    @test parse_failures(root, ["src/good.jl", "src/bad.jl"]) == ["src/bad.jl"]
  end

  @testset "a real repository" begin
    root = mktempdir()
    mkpath(joinpath(root, "src"))
    mkpath(joinpath(root, "test"))
    mkpath(joinpath(root, "code_ratchet"))
    write(
      joinpath(root, "src/simple.jl"),
      """
plain(x) = x + 1
""",
    )
    write(
      joinpath(root, "src/branchy.jl"),
      """
function branchy(x)
  if x > 10
    return 1
  elseif x > 5
    return 2
  elseif x > 0
    return 3
  else
    return 4
  end
end
""",
    )
    write(joinpath(root, "test/runtests.jl"), "using Test\n")
    write(
      joinpath(root, "code_ratchet/rulings.toml"),
      """
[scope]
measure = ["src/"]

[thresholds]
cyclomatic = 3
cognitive = 15
argcount = 10

[[unmeasured_path]]
path = "test/"
reason = "Test code."
""",
    )

    @testset "measure produces one row per scoped file" begin
      rows = measure(Complexity(), root)
      @test sort(collect(keys(rows))) == ["src/branchy.jl", "src/simple.jl"]
      @test rows["src/simple.jl"]["cyc"] == 1
      @test rows["src/branchy.jl"]["cyc"] >= 4
    end

    @testset "first check has no baseline, so everything is new" begin
      report = check(Complexity(), root)
      @test isempty(report.violations)
      @test sort(report.new_files) == ["src/branchy.jl", "src/simple.jl"]
    end

    @testset "refresh then check is clean" begin
      refresh(Complexity(), root)
      @test isfile(joinpath(root, "code_ratchet/complexity_baseline.toml"))
      report = check(Complexity(), root)
      @test ok(report)
      @test isempty(report.violations)
    end

    @testset "the maximum binds and the sum does not" begin
      # A trivial helper raises every *_sum and leaves every max alone.
      open(joinpath(root, "src/branchy.jl"), "a") do io
        println(io, "helper(y) = y")
      end
      report = check(Complexity(), root)
      @test ok(report)

      rows = measure(Complexity(), root)
      base, _ = read_baseline(Complexity(), joinpath(root, "code_ratchet"))
      @test rows["src/branchy.jl"]["cyc_sum"] > base["src/branchy.jl"]["cyc_sum"]
      @test rows["src/branchy.jl"]["cyc"] == base["src/branchy.jl"]["cyc"]
    end

    @testset "a rise in the maximum fails" begin
      write(
        joinpath(root, "src/simple.jl"),
        """
function nowbranchy(x)
  if x > 1
    return 1
  elseif x > 0
    return 2
  end
  return 3
end
""",
      )
      report = check(Complexity(), root)
      @test !ok(report)
      @test any(v -> v.path == "src/simple.jl" && v.key == "cyc", report.violations)
    end

    @testset "refresh refuses a rise without the flag" begin
      @test_throws ErrorException refresh(Complexity(), root)
      report = refresh(Complexity(), root; accept_rise=true)
      @test !isempty(report.violations)
      @test ok(check(Complexity(), root))
    end

    @testset "an unparsable file fails the gate" begin
      write(joinpath(root, "src/broken.jl"), "function h(z\nend\n")
      report = check(Complexity(), root)
      @test "src/broken.jl" in report.unparsable
      @test !ok(report)
      rm(joinpath(root, "src/broken.jl"))
    end

    @testset "a file measured by nothing fails the gate" begin
      mkpath(joinpath(root, "bench"))
      write(joinpath(root, "bench/run.jl"), "x = 1\n")
      report = check(Complexity(), root)
      @test "bench/run.jl" in report.unscoped
      @test !ok(report)
      rm(joinpath(root, "bench"); recursive=true)
    end

    @testset "thresholds rank work and never gate it" begin
      found = candidates(root)
      @test !isempty(found)
      @test all(d -> d.value > 3 || d.key != "cyc", found)
      # above threshold, yet the gate is green
      @test ok(check(Complexity(), root))
    end
  end

  @testset "coverage exemptions" begin
    root = mktempdir()
    mkpath(joinpath(root, "src"))
    mkpath(joinpath(root, "code_ratchet"))
    write(joinpath(root, "src/a.jl"), "f(x) = x\n")
    write(
      joinpath(root, "code_ratchet/rulings.toml"),
      """
[scope]
measure = ["src/"]

[[exemption]]
path = "src/a.jl"
misses = 2
reason = "Unreachable on this platform."
""",
    )
    write(
      joinpath(root, "lcov.info"),
      """
SF:$(joinpath(root, "src/a.jl"))
DA:1,1
DA:2,0
DA:3,0
end_of_record
""",
    )

    @testset "an exemption lowers the binding number" begin
      rows = measure(Coverage(), root)
      @test rows["src/a.jl"]["misses"] == 0
      @test rows["src/a.jl"]["exempt"] == 2
      @test rows["src/a.jl"]["lines"] == 3
    end

    @testset "an exemption wider than the misses is stale" begin
      write(
        joinpath(root, "lcov.info"),
        """
SF:$(joinpath(root, "src/a.jl"))
DA:1,1
DA:2,0
end_of_record
""",
      )
      stale = stale_exemptions(root)
      @test length(stale) == 1
      @test occursin("exempts 2", stale[1])
    end

    @testset "an exemption without a reason is refused" begin
      write(
        joinpath(root, "code_ratchet/rulings.toml"),
        """
[scope]
measure = ["src/"]

[[exemption]]
path = "src/a.jl"
reason = "no count given"
""",
      )
      @test_throws ErrorException exempt_counts(
        read_rulings(joinpath(root, "code_ratchet"))
      )
    end
  end

  @testset "coverage binds on misses, not percentage" begin
    root = mktempdir()
    mkpath(joinpath(root, "src"))
    mkpath(joinpath(root, "code_ratchet"))
    write(joinpath(root, "src/a.jl"), "f(x) = x\n")
    write(
      joinpath(root, "code_ratchet/rulings.toml"),
      """
[scope]
measure = ["src/"]
""",
    )
    # 2 of 4 covered: 50%, 2 misses
    write(
      joinpath(root, "lcov.info"),
      """
SF:$(joinpath(root, "src/a.jl"))
DA:1,1
DA:2,1
DA:3,0
DA:4,0
end_of_record
""",
    )
    refresh(Coverage(), root)

    @testset "adding covered lines raises the percentage and is quiet" begin
      write(
        joinpath(root, "lcov.info"),
        """
SF:$(joinpath(root, "src/a.jl"))
DA:1,1
DA:2,1
DA:3,0
DA:4,0
DA:5,1
DA:6,1
end_of_record
""",
      )
      @test ok(check(Coverage(), root))
    end

    @testset "gaining a miss while the percentage rises still fails" begin
      # 6 of 9 covered is 67%, up from 50%, but misses went 2 -> 3.
      write(
        joinpath(root, "lcov.info"),
        """
SF:$(joinpath(root, "src/a.jl"))
DA:1,1
DA:2,1
DA:3,0
DA:4,0
DA:5,1
DA:6,1
DA:7,1
DA:8,1
DA:9,0
end_of_record
""",
      )
      report = check(Coverage(), root)
      @test !ok(report)
      @test report.violations[1].from == 2 && report.violations[1].to == 3
    end
  end

  @testset "baseline round trip" begin
    root = mktempdir()
    dir = joinpath(root, "code_ratchet")
    mkpath(dir)
    rows = Dict("src/a.jl" => fake(3, 30), "src/b with space.jl" => fake(4, 40))
    write_baseline(Fake(), dir, rows, root)
    back, prov = read_baseline(Fake(), dir)
    @test back == rows
    @test prov["binding"] == ["bind"]
  end

  @testset "a missing rulings file is an error" begin
    @test_throws ErrorException read_rulings(mktempdir())
  end

  include("jet_metric.jl")
end
