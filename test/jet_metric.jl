# The JET adapter's own logic: attribution and dismissal.
#
# `report_package` is JET's responsibility and is not retested here. What is
# tested is the part this package wrote, which is also the part that silently
# degrades: a broken `attribute` produces all-zero rows forever, and a gate
# that stops measuring without failing is worse than no gate.
#
# Reports are synthesised rather than provoked, so these run in milliseconds
# and do not need a loadable fixture package.

using JET: JET
using Test
using CodeRatchet: CodeRatchet, Rulings, read_rulings

const EXT = Base.get_extension(CodeRatchet, :CodeRatchetJETExt)

struct StubFrame
  file::Symbol
  line::Int
end

# `nameof(typeof(...))` is what a dismissal matches on `class`, so the stub
# names below stand in for real JET report types.
struct MethodErrorReport
  vst::Vector{StubFrame}
  message::String
end
Base.show(io::IO, r::MethodErrorReport) = print(io, "MethodErrorReport(", r.message, ")")

struct UncaughtExceptionReport
  vst::Vector{StubFrame}
  message::String
end
function Base.show(io::IO, r::UncaughtExceptionReport)
  return print(io, "UncaughtExceptionReport(", r.message, ")")
end

function rulings_with(body::AbstractString)
  dir = mktempdir()
  write(joinpath(dir, "rulings.toml"), "[scope]\nmeasure = [\"src/\"]\n\n" * body)
  return read_rulings(dir)
end

@testset "JET adapter" begin
  root = mktempdir()
  mkpath(joinpath(root, "src"))
  write(joinpath(root, "src/inner.jl"), "f(x) = x\n")
  write(joinpath(root, "src/outer.jl"), "g() = f(1)\n")

  @testset "attribution takes the DEEPEST repository frame" begin
    # JET orders vst outermost first, so the innermost repo frame is last.
    report = MethodErrorReport(
      [
        StubFrame(Symbol(joinpath(root, "src/outer.jl")), 1),
        StubFrame(Symbol(joinpath(root, "src/inner.jl")), 1),
      ],
      "no matching method found",
    )
    @test EXT.attribute(report, root) == "src/inner.jl"
  end

  @testset "a frame outside the repository is skipped" begin
    report = MethodErrorReport(
      [
        StubFrame(Symbol(joinpath(root, "src/inner.jl")), 1),
        StubFrame(Symbol("/usr/share/julia/base/array.jl"), 99),
      ],
      "no matching method found",
    )
    @test EXT.attribute(report, root) == "src/inner.jl"
  end

  @testset "top-level and empty frames are skipped" begin
    report = MethodErrorReport(
      [
        StubFrame(Symbol(joinpath(root, "src/inner.jl")), 1),
        StubFrame(Symbol("top-level"), 3),
        StubFrame(Symbol(""), 0),
      ],
      "no matching method found",
    )
    @test EXT.attribute(report, root) == "src/inner.jl"
  end

  @testset "a report with no repository frame is attributed to nothing" begin
    report = MethodErrorReport([StubFrame(Symbol("/elsewhere/x.jl"), 1)], "boom")
    @test EXT.attribute(report, root) === nothing
  end

  @testset "dismissal by class" begin
    rulings = rulings_with("""
    [[dismissal]]
    class = "MethodErrorReport"
    reason = "fixture"
    """)
    @test EXT.dismissed(MethodErrorReport(StubFrame[], "anything"), rulings)
    @test !EXT.dismissed(UncaughtExceptionReport(StubFrame[], "anything"), rulings)
  end

  @testset "dismissal by pattern" begin
    rulings = rulings_with("""
    [[dismissal]]
    pattern = "Symbol"
    reason = "fixture"
    """)
    @test EXT.dismissed(MethodErrorReport(StubFrame[], "`*(::Int64, ::Symbol)`"), rulings)
    @test !EXT.dismissed(MethodErrorReport(StubFrame[], "`+(::Int64, ::String)`"), rulings)
  end

  @testset "class and pattern together narrow rather than widen" begin
    rulings = rulings_with("""
    [[dismissal]]
    class = "MethodErrorReport"
    pattern = "Symbol"
    reason = "fixture"
    """)
    @test EXT.dismissed(MethodErrorReport(StubFrame[], "::Symbol"), rulings)
    # right class, wrong message
    @test !EXT.dismissed(MethodErrorReport(StubFrame[], "::String"), rulings)
    # right message, wrong class
    @test !EXT.dismissed(UncaughtExceptionReport(StubFrame[], "::Symbol"), rulings)
  end

  @testset "a dismissal with no reason is refused" begin
    rulings = rulings_with("""
    [[dismissal]]
    class = "MethodErrorReport"
    """)
    @test_throws ErrorException EXT.dismissed(MethodErrorReport(StubFrame[], "x"), rulings)
  end

  @testset "a dismissal matching everything is refused" begin
    rulings = rulings_with("""
    [[dismissal]]
    reason = "would dismiss every report"
    """)
    @test_throws ErrorException EXT.dismissed(MethodErrorReport(StubFrame[], "x"), rulings)
  end

  @testset "the jet block is required" begin
    @test_throws ErrorException EXT.jet_settings(rulings_with(""))
    settings = EXT.jet_settings(rulings_with("""
    [jet]
    package = "Thing"
    """))
    @test settings.package == "Thing"
    @test settings.targets == ["Thing"]   # defaults to the package
    @test isempty(settings.load)
  end

  @testset "provenance records the commit and the load set" begin
    repo = mktempdir()
    mkpath(joinpath(repo, "code_ratchet"))
    write(
      joinpath(repo, "code_ratchet/rulings.toml"),
      """
      [scope]
      measure = ["src/"]

      [jet]
      package = "Thing"
      load = ["B", "A"]
      """,
    )
    prov = CodeRatchet.provenance(EXT.Inference(), repo)
    @test prov["package"] == "Thing"
    @test prov["load_set"] == ["A", "B"]   # sorted, so the order cannot drift
    @test haskey(prov, "commit")
  end

  @testset "the metric's shape" begin
    metric = EXT.Inference()
    @test CodeRatchet.metric_name(metric) == "jet"
    @test CodeRatchet.binding(metric) == ("reviewed",)
    @test "raw" in CodeRatchet.row_numbers(metric)
    # raw is recorded but does not bind: a new instance of a dismissed class
    # must stay green, which is the whole reason for the split.
    @test !("raw" in CodeRatchet.binding(metric))
  end
end
