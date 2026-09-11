# `all` and `init`: running every gate at once, and getting a repository to the
# point where it can.

using Test
using CodeRatchet
using TOML: TOML
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

  @testset "metric construction uses the selected ratchet directory" begin
    root = gitrepo(Dict("src/a.jl" => "f(x) = x\n"); rulings=THREE)
    custom = joinpath(root, "quality")
    mkpath(custom)
    write(
      joinpath(custom, CodeRatchet.RULINGS),
      """
      [metrics]
      run = ["style"]

      [scope]
      measure = ["src/"]

      [style]
      rules = ["underscore_name"]
      """,
    )
    metrics = configured_metrics(root; dir=custom)
    @test length(metrics) == 1
    @test CodeRatchet.binding(only(metrics)) == ("underscore_name",)
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

  @testset "malformed package metadata is treated as no package" begin
    root = mktempdir()
    write(joinpath(root, "Project.toml"), "[")
    @test package_identity(root) == (name="", uuid="")
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

  # Found by running init on CodeRatchet's own repository: the package under
  # measurement being the tool itself emitted the dependency twice, and the
  # result was TOML that does not parse.
  @testset "generated projects pin the exact CodeRatchet revision" begin
    pin = "a"^40
    withenv("CODERATCHET_REV" => pin) do
      project = CodeRatchet.ratchet_project((name="Demo", uuid="aaaa-bbbb"))
      @test occursin("rev = \"$pin\"", project)
    end
    withenv("CODERATCHET_REV" => "main") do
      @test_throws ErrorException CodeRatchet.coderatchet_revision()
    end
    @test CodeRatchet.exact_git_revision(uppercase(pin)) == pin
    @test CodeRatchet.exact_git_revision("b"^64) == "b"^64
    @test_throws ErrorException CodeRatchet.exact_git_revision("deadbeef")
  end

  @testset "manifest revision resolution is immutable and version-aware" begin
    root = mktempdir()
    project = joinpath(root, "Project.toml")
    write(project, "name = \"Fixture\"\n")
    generic = "b"^40
    versioned = "c"^40
    write(
      joinpath(root, "Manifest.toml"), "[[deps.CodeRatchet]]\nrepo-rev = \"$generic\"\n"
    )
    versioned_manifest = joinpath(root, "Manifest-v$(VERSION.major).$(VERSION.minor).toml")
    write(versioned_manifest, "[[deps.CodeRatchet]]\nrepo-rev = \"$versioned\"\n")

    @test CodeRatchet.manifest_coderatchet_revision(project) == versioned
    withenv("CODERATCHET_REV" => "d"^40) do
      @test CodeRatchet.installed_coderatchet_revision(project) == versioned
    end

    rm(versioned_manifest)
    @test CodeRatchet.manifest_coderatchet_revision(project) == generic

    write(joinpath(root, "Manifest.toml"), "[[deps.CodeRatchet]]\nrepo-rev = \"main\"\n")
    @test_throws ErrorException CodeRatchet.installed_coderatchet_revision(project)
  end

  @testset "manifest revision resolution refuses ambiguous metadata" begin
    root = mktempdir()
    project = joinpath(root, "Project.toml")
    manifest = joinpath(root, "Manifest.toml")
    write(project, "name = \"Fixture\"\n")

    @test CodeRatchet.manifest_coderatchet_revision(nothing) == ""
    @test CodeRatchet.manifest_coderatchet_revision(project) == ""

    write(manifest, "[deps]\nOther = []\n")
    @test CodeRatchet.manifest_coderatchet_revision(project) == ""

    first = "a"^40
    second = "b"^40
    write(
      manifest,
      "[[deps.CodeRatchet]]\nrepo-rev = \"$first\"\n" *
      "[[deps.CodeRatchet]]\nrepo-rev = \"$second\"\n",
    )
    @test CodeRatchet.manifest_coderatchet_revision(project) == ""

    write(manifest, "[deps]\nCodeRatchet = [\"not-a-table\"]\n")
    @test CodeRatchet.manifest_coderatchet_revision(project) == ""
  end

  @testset "installed revision refuses an unidentified checkout" begin
    root = mktempdir()
    project = joinpath(root, "Project.toml")
    write(project, "name = \"Fixture\"\n")
    withenv("PATH" => "") do
      @test CodeRatchet.checkout_coderatchet_revision() == ""
      @test_throws ErrorException CodeRatchet.installed_coderatchet_revision(project)
    end
  end

  @testset "the reusable workflow binds its implementation revision" begin
    workflow = read(
      normpath(joinpath(@__DIR__, "..", ".github", "workflows", "ratchet.yml")), String
    )
    @test occursin("job.workflow_sha", workflow)
    @test occursin("installed_coderatchet_revision()", workflow)
    @test !occursin("ratchet.yml@main", workflow)
  end

  @testset "the generated Project.toml parses" begin
    for name in ("Demo", "CodeRatchet")
      root = gitrepo(
        Dict(
          "Project.toml" => "name = $(repr(name))\nuuid = \"aaaa-bbbb\"\n",
          "src/$name.jl" => "module $name end\n",
        ),
      )
      initialise(root)
      raw = TOML.parsefile(joinpath(ratchet_dir(root), "Project.toml"))
      @test haskey(raw["deps"], "CodeRatchet")
      @test haskey(raw, "sources")
    end
  end

  @testset "a repository whose package is the tool names it once" begin
    root = gitrepo(
      Dict(
        "Project.toml" => "name = \"CodeRatchet\"\nuuid = \"0e86a969\"\n",
        "src/CodeRatchet.jl" => "module CodeRatchet end\n",
      ),
    )
    initialise(root)
    raw = TOML.parsefile(joinpath(ratchet_dir(root), "Project.toml"))
    @test length(raw["deps"]) == 2                     # itself and JET
    @test raw["sources"]["CodeRatchet"] == Dict("path" => "..")
  end

  @testset "a guessed reason is offered for a known directory, flagged for others" begin
    @test occursin("Test code", unmeasured_reason("test/"))
    @test occursin("Replace this reason", unmeasured_reason("weird/"))
  end
end

include("coldstart_metric.jl")
