using CodeRatchet
using Test

# A throwaway package directory holding `files`, a map from relative path to text.
function with_package(f, files::Pair{String,String}...)
  dir = mktempdir()
  for (rel, text) in files
    path = joinpath(dir, rel)
    mkpath(dirname(path))
    write(path, text)
  end
  return f(dir)
end

place(f) = (f.file, f.line, f.what)

@testset "CodeRatchet" begin
  @testset "complexity" begin
    src = """
    function flat(x)
      return x
    end

    function branchy(x)
      if x > 1
        return 1
      elseif x > 0
        return 2
      end
      for i in 1:x
        i > 2 && return i
      end
      return 0
    end
    """
    with_package("src/a.jl" => src) do dir
      found = complexity(dir)
      @test first(found).what == "branchy"
      @test first(found).file == "src/a.jl"
      @test first(found).line == 5
      @test first(found).value > only(filter(f -> f.what == "flat", found)).value
      @test all(f -> f.value >= 1, found)
      @test issorted(found; by=f -> -f.value)
      @test isempty(complexity(dir; over=1000))
      @test !isempty(complexity(dir; by=:cognitive))
      @test !isempty(complexity(dir; by=:arguments))
      @test_throws ArgumentError complexity(dir; by=:bogus)
    end
  end

  @testset "argument counts, including return-annotated signatures" begin
    src = """
    function plain(a, b, c, d, e, f)
      return 1
    end
    function annotated(a, b, c, d, e, f)::Int
      return 1
    end
    function annotated_where(a, b, c, d, e, f)::T where {T}
      return 1
    end
    short(a, b, c)::Int = 1
    withkw(a, b; k = 1, l = 2, rest...) = 1
    none() = 1
    """
    with_package("src/a.jl" => src) do dir
      found = complexity(dir; by=:arguments, over=0)
      counts = Dict(f.what => f.value for f in found)
      @test counts == Dict(
        "plain" => 6,
        "annotated" => 6,
        "annotated_where" => 6,
        "short" => 3,
        "withkw" => 5,
        "none" => 0,
      )
      @test only(filter(f -> f.what == "annotated", found)).line == 4
    end
  end

  @testset "a return annotation does not rename a definition" begin
    src = """
    module Named
    export typed
    typed(x)::Int = x
    function longform(x)::Int
      return x
    end
    end
    """
    with_package("src/Named.jl" => src) do dir
      @test [f.what for f in docstrings(dir)] == ["typed"]
      lcov = joinpath(dir, "lcov.info")
      write(lcov, "SF:src/Named.jl\nDA:3,0\nDA:5,0\nend_of_record\n")
      @test sort([f.what for f in coverage(dir; lcov)]) == ["longform", "typed"]
    end
  end

  @testset "style" begin
    src = """
    function a(x::Union{Nothing,Int})
      return x
    end
    b(x::Union{Int,Float64}) = x
    function _hidden()
      return f(k = 1)
    end
    function declared(x, k = 2)
      return g(x; k = 3)
    end
    """
    with_package("src/a.jl" => src, "src/_internal.jl" => "x = 1\n") do dir
      found = style(dir)
      by_rule(rule) = [f for f in found if f.what == rule]
      @test [f.line for f in by_rule("union_nothing")] == [1]
      @test sort([place(f) for f in by_rule("underscore_name")]) == [("src/_internal.jl", 1, "underscore_name"), ("src/a.jl", 5, "underscore_name")]
      # `f(k = 1)` is a keyword call; `declared(x, k = 2)` is an optional positional.
      @test [f.line for f in by_rule("implicit_kwarg")] == [6]
      @test first(by_rule("implicit_kwarg")).detail == "return f(k = 1)"
      @test [f.what for f in style(dir; rules=[:union_nothing])] == ["union_nothing"]
      @test_throws ArgumentError style(dir; rules=[:bogus])
    end
  end

  @testset "docstrings" begin
    src = """
    module Fixture
    export documented, bare, Thing, many
    public hidden
    \"\"\"Documented.\"\"\"
    documented(x) = x
    bare(x) = x
    struct Thing end
    \"\"\"Many methods, one docstring.\"\"\"
    function many end
    many(x::Int) = x
    many(x::Float64) = x
    hidden() = 1
    internal() = 2
    end
    """
    with_package("src/Fixture.jl" => src) do dir
      found = docstrings(dir)
      @test sort([f.what for f in found]) == ["Thing", "bare", "hidden"]
      @test only(filter(f -> f.what == "bare", found)).line == 6
      # `internal` is not declared public and `many` is documented once.
      @test !any(f -> f.what in ("internal", "many", "documented"), found)
    end
  end

  @testset "boxes" begin
    src = """
    module BoxFixture
    function counter()
      n = 0
      bump = () -> (n += 1; n)
      return bump
    end
    function clean(x)
      return map(y -> y + x, 1:3)
    end
    end
    """
    with_package("src/BoxFixture.jl" => src) do dir
      fixture = Base.include(Main, joinpath(dir, "src", "BoxFixture.jl"))
      found = boxes(fixture; root=dir)
      @test length(found) == 1
      @test only(found).what == "counter"
      @test only(found).file == "src/BoxFixture.jl"
      @test occursin("`n`", only(found).detail)
    end
    @test_throws ArgumentError boxes(Main)
  end

  @testset "coverage from a tracefile" begin
    src = """
    function covered(x)
      return x
    end
    function partial(x)
      if x
        return 1
      end
      return 2
    end
    const table = Dict(1 => 2)
    """
    with_package("src/a.jl" => src) do dir
      lcov = joinpath(dir, "lcov.info")
      write(
        lcov,
        join(
          [
            "SF:src/a.jl",
            "DA:2,3",
            "DA:5,1",
            "DA:6,0",
            "DA:8,0",
            "DA:10,0",
            "end_of_record",
          ],
          "\n",
        ) * "\n",
      )
      found = coverage(dir; lcov)
      @test [(f.what, f.value) for f in found] == [("partial", 2), ("table", 1)]
      @test first(found).line == 6
      @test first(found).detail == "uncovered lines: 6, 8"
      @test isempty(coverage(dir; lcov, paths=["elsewhere"]))
      # A file the tracefile never mentions was never loaded: all of it is a miss.
      write(joinpath(dir, "src", "b.jl"), "function never(x)\n  return x\nend\n")
      never = coverage(dir; lcov)
      @test ("never", 2) in [(f.what, f.value) for f in never if f.file == "src/b.jl"]
      @test_throws ArgumentError coverage(dir; lcov=joinpath(dir, "missing.info"))
    end
  end

  @testset "coverage runs the tests" begin
    pkg = """
    module Tiny
    export used
    used(x) = x + 1
    unused(x) = x - 1
    end
    """
    proj = """
    name = "Tiny"
    uuid = "5d2a7a5e-1c21-4c53-8f0a-6e3a1b0d7f10"
    version = "0.1.0"

    [extras]
    Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"

    [targets]
    test = ["Test"]
    """
    tests = "using Test, Tiny\n@test used(1) == 2\n"
    with_package(
      "Project.toml" => proj, "src/Tiny.jl" => pkg, "test/runtests.jl" => tests
    ) do dir
      found = redirect_stdout(devnull) do
        coverage(dir)
      end
      @test [(f.what, f.line) for f in found] == [("unused", 4)]
    end
  end

  @testset "files that do not parse are refused" begin
    with_package("src/a.jl" => "function broken(\n") do dir
      @test_throws ArgumentError complexity(dir)
      @test_throws ArgumentError style(dir)
      @test_throws ArgumentError docstrings(dir)
    end
  end

  @testset "report" begin
    with_package("src/a.jl" => "f(x) = x\n") do dir
      io = IOBuffer()
      found = report(dir; io)
      @test keys(found) == (:complexity, :style, :docstrings)
      out = String(take!(io))
      @test occursin("complexity (cyclomatic)", out)
      @test occursin("docstrings: 0 findings", out)
    end
  end

  @testset "findings display" begin
    items = [CodeRatchet.Finding("src/a.jl", i, "f$i", i, "") for i in 1:25]
    shown = sprint(show, MIME"text/plain"(), CodeRatchet.ranked("demo", items))
    @test occursin("demo: 25 findings, worst 20", shown)
    @test occursin("… 5 more", shown)
  end
end
