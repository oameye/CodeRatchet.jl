# `all` and `init`: running every gate at once, and getting a repository to the
# point where it can.

using Test
using CodeRatchet
using CodeRatchet:
  Complexity,
  Docstrings,
  Style,
  configured_metrics,
  debt,
  initialise,
  metric_name,
  package_identity,
  refresh,
  scope_split,
  scorecard,
  unmeasured_reason

const THREE = """
[metrics]
run = ["docs", "complexity", "style"]

[scope]
measure = ["src/"]

[thresholds]
cyclomatic = 2

[style]
rules = ["union_nothing"]
"""

@testset "running every gate at once" begin
  @testset "cost order is the package's, not the repository's" begin
    root = gitrepo(Dict("src/a.jl" => "f(x) = x"); rulings=THREE)
    # Written docs, complexity, style. Run cheapest first regardless, so a
    # repository cannot accidentally put the minutes-long gate in front.
    @test [metric_name(m) for m in configured_metrics(root)] == ["complexity", "style", "docs"]
  end

  @testset "no metrics configured is an error, not a run of nothing" begin
    root = gitrepo(
      Dict("src/a.jl" => "f(x) = x"); rulings="[scope]\nmeasure = [\"src/\"]\n"
    )
    @test_throws ErrorException configured_metrics(root)
  end

  @testset "an unknown metric name is refused" begin
    root = gitrepo(
      Dict("src/a.jl" => "f(x) = x");
      rulings="[metrics]\nrun = [\"complexity\", \"nope\"]\n\n[scope]\nmeasure = [\"src/\"]\n",
    )
    @test_throws ErrorException configured_metrics(root)
  end

  # A repository whose JET is already gated absolutely by another workflow
  # should not pay for JET twice in CI. Narrowing is legitimate; widening would
  # be a second source of truth.
  @testset "--only narrows the configured set" begin
    root = gitrepo(Dict("src/a.jl" => "f(x) = x"); rulings=THREE)
    @test [metric_name(m) for m in configured_metrics(root; only=["style", "docs"])] == ["style", "docs"]
  end

  @testset "--only cannot add a metric the repository did not configure" begin
    root = gitrepo(Dict("src/a.jl" => "f(x) = x"); rulings=THREE)
    @test_throws ErrorException configured_metrics(root; only=["jet"])
  end

  @testset "--only keeps cost order, not the order it was written in" begin
    root = gitrepo(Dict("src/a.jl" => "f(x) = x"); rulings=THREE)
    @test [metric_name(m) for m in configured_metrics(root; only=["docs", "complexity"])] == ["complexity", "docs"]
  end

  @testset "the group verb exits nonzero when any single gate fails" begin
    root = gitrepo(Dict("src/a.jl" => "f(x) = x\n"); rulings=THREE)
    withenv("CODERATCHET_ROOT" => root) do
      @test CodeRatchet.main(["all", "refresh"]) == 0
      @test CodeRatchet.main(["all", "check"]) == 0
      track!(root, "src/a.jl", "f(x) = x\ng(y::Union{Nothing,Int}) = y\n")
      @test CodeRatchet.main(["all", "check"]) == 1
    end
  end

  @testset "an unknown group verb is refused" begin
    root = gitrepo(Dict("src/a.jl" => "f(x) = x"); rulings=THREE)
    withenv("CODERATCHET_ROOT" => root) do
      @test CodeRatchet.main(["all", "wat"]) == 2
    end
  end
end

@testset "the scorecard" begin
  # A maximum is not debt. Every non-empty file has a cyclomatic maximum of at
  # least one, so listing it would bury the numbers that mean something.
  @testset "a maximum is not debt, a count above threshold is" begin
    @test !debt(Complexity(), "cyc")
    @test !debt(Complexity(), "cog")
    @test debt(Complexity(), "cyc_over")
    @test debt(Docstrings(), "undocumented")
  end

  @testset "a clean repository says so rather than listing every file" begin
    root = gitrepo(Dict("src/a.jl" => "f(x) = x\n"); rulings=THREE)
    refresh(Complexity(), root)
    refresh(Style(root), root)
    refresh(Docstrings(), root)
    @test occursin("Every file is at zero", sprint(show, scorecard(root)))
  end

  @testset "files rank by how many metrics flag them" begin
    rulings = """
    [metrics]
    run = ["complexity", "style"]

    [scope]
    measure = ["src/"]

    [thresholds]
    cyclomatic = 1

    [style]
    rules = ["union_nothing"]
    """
    both = "g(y::Union{Nothing,Int}) = y > 1 ? 1 : 2\n"
    one = "h(z) = z > 1 ? 1 : 2\n"
    root = gitrepo(Dict("src/both.jl" => both, "src/one.jl" => one); rulings)
    refresh(Complexity(), root)
    refresh(Style(root), root)

    card = scorecard(root)
    @test first(first(card.rows)) == "src/both.jl"
    @test length(first(card.rows)[2]) == 2
    text = sprint(show, card)
    @test occursin("cyc_over=1", text)
    @test !occursin("cyc=", replace(text, "cyc_over=" => ""))
  end
end

@testset "init" begin
  demo() = gitrepo(
    Dict(
      "Project.toml" => "name = \"Demo\"\nuuid = \"aaaa-bbbb\"\nversion = \"0.1.0\"\n",
      "src/Demo.jl" => "module Demo\nf(x) = x\nend\n",
      "test/runtests.jl" => "using Test\n",
      "docs/make.jl" => "using Documenter\n",
      "benchmark/run.jl" => "using BenchmarkTools\n",
    ),
  )

  @testset "the package identifies itself from its own Project.toml" begin
    identity = package_identity(demo())
    @test identity.name == "Demo"
    @test identity.uuid == "aaaa-bbbb"
  end

  @testset "a repository with no package is still scaffoldable" begin
    identity = package_identity(gitrepo(Dict("src/a.jl" => "f(x) = x")))
    @test identity.name == ""
  end

  # The generated config is complete on the first run. A hand-written one
  # almost always misses a directory, and the gate's first output is then a
  # list of orphaned files rather than a green tick.
  @testset "every tracked directory is either measured or declared" begin
    root = demo()
    measured, unmeasured = scope_split(root)
    @test measured == ["src/"]
    @test unmeasured == ["benchmark/", "docs/", "test/"]

    initialise(root)
    @test isempty(CodeRatchet.unscoped_files(root, read_rulings(ratchet_dir(root))))
  end

  @testset "the first check is green, not a wall of orphans" begin
    root = demo()
    initialise(root)
    withenv("CODERATCHET_ROOT" => root) do
      @test CodeRatchet.main(["all", "refresh"]) == 0
      @test CodeRatchet.main(["all", "check"]) == 0
    end
  end

  @testset "only the metrics needing no extra setup are switched on" begin
    root = demo()
    initialise(root)
    @test [metric_name(m) for m in configured_metrics(root)] == ["complexity", "style", "docs"]
  end

  # rulings.toml is the half a human wrote. Losing it to a scaffolding command
  # would be the worst thing this package could do to someone.
  @testset "an existing rulings file is never overwritten by accident" begin
    root = demo()
    initialise(root)
    write(joinpath(ratchet_dir(root), CodeRatchet.RULINGS), "# mine\n")
    @test isempty(initialise(root))
    @test read(joinpath(ratchet_dir(root), CodeRatchet.RULINGS), String) == "# mine\n"
    @test !isempty(initialise(root; force=true))
  end

  @testset "a guessed reason is offered for a known directory, flagged for others" begin
    @test occursin("Test code", unmeasured_reason("test/"))
    @test occursin("Replace this reason", unmeasured_reason("weird/"))
  end
end
