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

  # A package whose compiler facts are known: `h` calls `g` through an abstract
  # container, so each element type enters inference unless precompiled.
  function compiler_fixture(f; precompile_g::Bool=false)
    uuid = "9b1a6f20-7c5d-4d1e-8c0e-0a5f4f3a1c11"
    src = """
    module Inval
    export applyf, h
    struct Foo end
    f(::Int) = 1
    f(::Bool) = 2
    applyf(c) = f(c[1])
    g(x) = x + 1
    h(c) = g(c[1])
    $(precompile_g ? "precompile(g, (Int,))" : "")
    precompile(Base.copy, (Vector{Foo},))
    precompile(Base.reverse, (Vector{Foo},))
    end
    """
    return with_package(
      f,
      "Project.toml" => "name = \"Inval\"\nuuid = \"$uuid\"\nversion = \"0.1.0\"\n",
      "src/Inval.jl" => src,
    )
  end

  @testset "invalidations" begin
    compiler_fixture() do dir
      work = "using Inval; Inval.applyf(Any[1]); @eval Inval f(::AbstractFloat) = 3"
      found = invalidations(dir; workload=work)
      @test length(found) == 1
      @test occursin("f(::AbstractFloat)", only(found).what)
      @test only(found).value >= 1
      @test occursin("owner Inval", only(found).detail)
      # A method defined elsewhere is not the package's to answer for, unless named.
      other =
        "module Other\nf(::Int) = 1\napplyf(c) = f(c[1])\nend\n" *
        "Other.applyf(Any[1]); @eval Other f(::AbstractFloat) = 3"
      @test isempty(invalidations(dir; workload=other))
      @test length(invalidations(dir; workload=other, all=true)) == 1
      @test length(invalidations(dir; workload=other, owners=["Main"])) == 1
      # Redefining a constant logs events SnoopCompile cannot parse. They are
      # reported without a name, and method events in the same capture still parse.
      mixed =
        "module Other\nconst X = 1\nf() = X\ng(::Int) = 1\napplyg(c) = g(c[1])\nend\n" *
        "Other.f(); Other.applyg(Any[1]); @eval Other g(::AbstractFloat) = 3; " *
        "@eval Other const X = 2"
      both = invalidations(dir; workload=mixed, all=true)
      @test any(f -> startswith(f.what, "redefined binding"), both)
      @test any(f -> occursin("g(::AbstractFloat)", f.what), both)
      @test only(filter(f -> startswith(f.what, "redefined binding"), both)).value >= 1
      @test isempty(invalidations(dir; workload=mixed))
      # Loading the package alone invalidates nothing here.
      @test isempty(invalidations(dir))
    end
  end

  @testset "inference triggers" begin
    work = "using Inval; Inval.h(Any[1]); Inval.h(Any[2.0])"
    compiler_fixture() do dir
      found = triggers(dir; workload=work)
      sigs = [f.what for f in found]
      @test "Tuple{typeof(Inval.g), Int64}" in sigs
      @test "Tuple{typeof(Inval.g), Float64}" in sigs
      @test all(
        f -> f.file == "src/Inval.jl", filter(f -> occursin("Inval", f.what), found)
      )
      @test issorted(found; by=f -> -f.value)
      # A trigger in code the package does not own is listed, and can be filtered out.
      mixed =
        work * "; module Other\ng2(x) = x + 1\nh2(c) = g2(c[1])\nend; Other.h2(Any[1])"
      everything = triggers(dir; workload=mixed)
      ours = triggers(dir; workload=mixed, owned_only=true)
      @test any(f -> occursin("owner Main", f.detail), everything)
      @test !any(f -> occursin("owner Main", f.detail), ours)
      @test length(triggers(dir; workload=mixed, owned_only=true, owners=["Main"])) ==
        length(everything)
    end
    # Precompiling a signature removes exactly its trigger.
    compiler_fixture(; precompile_g=true) do dir
      sigs = [f.what for f in triggers(dir; workload=work)]
      @test "Tuple{typeof(Inval.g), Int64}" ∉ sigs
      @test "Tuple{typeof(Inval.g), Float64}" in sigs
    end
  end

  @testset "package image" begin
    compiler_fixture() do dir
      img = image(dir)
      @test img isa PackageImage
      @test img.package == "Inval"
      @test img.bytes > 0
      @test img.counts["specializations"] > 0
      names = [f.what for f in img.specialized]
      @test any(startswith("reverse("), names)
      @test all(f -> occursin("specializations; owner ", f.detail), img.specialized)
      @test isempty(image(dir; owned_only=true).specialized)
      shown = sprint(show, MIME"text/plain"(), img)
      @test occursin("package image of Inval", shown)
    end
  end

  @testset "keyword arguments inside signatures" begin
    src = """
    function a(x::T; k = g(a = 1), z) where {T}
      return x
    end
    b(p = g(q = 2)) = 1
    function c(x; k = 2)::Int
      return h(m = 3)
    end
    d(x)::Int = g(r = 4)
    function e(x; y)
      return x
    end
    """
    with_package("src/a.jl" => src) do dir
      lines = [f.line for f in style(dir; rules=[:implicit_kwarg])]
      # Defaults that call with a keyword count; the signatures' own `k = 2` and
      # `p = ...` (an optional positional) do not.
      @test sort(lines) == [1, 4, 6, 8]
    end
  end

  @testset "qualified Union and Nothing" begin
    src = """
    a(x::Core.Union{Base.Nothing,Int}) = x
    b(x::Union{1,Int}) = x
    c(x::Union{Int,Float64}) = x
    """
    with_package("src/a.jl" => src) do dir
      @test [f.line for f in style(dir; rules=[:union_nothing])] == [1]
    end
  end

  @testset "public declarations and definition kinds" begin
    src = """
    module Kinds
    using SciMLPublic: @public
    export Abstract, Prim, K, Typed, S, shown, dotted
    @public one, two
    @public three
    abstract type Abstract end
    primitive type Prim 8 end
    const K = 1
    const Typed::Int = 2
    @kwdef struct S
      x::Int = 1
    end
    Base.show(io::IO, s::S) = 1
    dotted(x)::Int = x
    function one() end
    two() = 1
    three() = 2
    shown = 1
    x::Int = 5
    a.b::Int = 6
    end
    """
    with_package("src/Kinds.jl" => src) do dir
      found = [f.what for f in docstrings(dir)]
      @test sort(found) ==
        sort(["Abstract", "Prim", "K", "Typed", "S", "dotted", "one", "two", "three"])
    end
  end

  @testset "names read from odd syntax" begin
    @test CodeRatchet.defname(1) == ""
    @test CodeRatchet.defname(:(x -> 1)) == ""
    # Through an inference barrier: a constant argument is folded away at compile
    # time, and the line that decides it then never runs.
    opaque = Base.inferencebarrier(1)
    @test CodeRatchet.names_union(opaque) == false
    @test CodeRatchet.is_nothing_type(opaque) == false
    @test CodeRatchet.definition_name(:(@thing 1)) == "@thing"
    @test CodeRatchet.definition_name(:(@kwdef struct S end)) == "S"
    @test CodeRatchet.definition_name(:(1 + 1)) == ""
  end

  @testset "a docstring on a macro-wrapped definition" begin
    src = """
    module Wrapped
    export Documented, Bare
    \"\"\"Documented.\"\"\"
    @kwdef struct Documented
      x::Int = 1
    end
    @kwdef struct Bare
      x::Int = 1
    end
    end
    """
    with_package("src/Wrapped.jl" => src) do dir
      @test [f.what for f in docstrings(dir)] == ["Bare"]
    end
  end

  @testset "a documented definition is attributed by name" begin
    src = """
    \"\"\"A documented function.\"\"\"
    function documented(x)
      if x
        return 1
      end
      return 2
    end
    """
    with_package("src/a.jl" => src) do dir
      lcov = joinpath(dir, "lcov.info")
      write(lcov, "SF:src/a.jl\nDA:4,0\nDA:6,0\nend_of_record\n")
      found = coverage(dir; lcov)
      @test [(f.what, f.value) for f in found] == [("documented", 2)]
    end
  end

  @testset "constant-return methods cannot be observed" begin
    src = """
    always(::Any) = false
    function nothing_at_all(x)
      return nothing
    end
    function real_work(x)
      return x + 1
    end
    """
    with_package("src/a.jl" => src) do dir
      lcov = joinpath(dir, "lcov.info")
      write(lcov, "SF:src/a.jl\nDA:1,0\nDA:3,0\nDA:6,0\nend_of_record\n")
      found = Dict(f.what => f for f in coverage(dir; lcov))
      @test occursin("constant-return", found["always"].detail)
      @test occursin("constant-return", found["nothing_at_all"].detail)
      @test !occursin("constant-return", found["real_work"].detail)
    end
  end

  @testset "what a target may be" begin
    @test_throws ArgumentError complexity(Main)
    with_package("src/a.jl" => "f(x) = x\n", "src/b.jl" => "g(x) = x\n") do dir
      found = complexity(dir; paths=["src/a.jl"])
      @test [f.file for f in found] == ["src/a.jl"]
      @test complexity(dir; paths=["nowhere"]) |> isempty
    end
    # A loaded package module stands for its own directory.
    @test !isempty(complexity(CodeRatchet))
  end

  @testset "boxes without a name, and without a body" begin
    lowered = Meta.lower(Main, Expr(:call, Core.Box, 1)).args[1]
    @test CodeRatchet.lowered_boxes(lowered) == [("<unnamed>",)]
    sourceless = only(methods(Core.setglobalonce!))
    @test isempty(CodeRatchet.method_boxes(sourceless))
  end

  @testset "compact display" begin
    found = CodeRatchet.ranked("demo", [CodeRatchet.Finding("src/a.jl", 1, "f", 2, "")])
    @test repr(found) == "Findings(\"demo\", 1)"
    @test occursin("1 finding", sprint(show, MIME"text/plain"(), found))
    @test sprint(
      show, MIME"text/plain"(), CodeRatchet.ranked("none", CodeRatchet.Finding[])
    ) == "none: 0 findings"
    @test repr(
      CodeRatchet.PackageImage("P", 1, Dict{String,Int}(), Dict{String,Int}(), found)
    ) == "PackageImage(\"P\")"
  end

  @testset "the tooling environment" begin
    dir = joinpath(mktempdir(), "env")
    # A failed install reports why, and leaves no manifest behind.
    err = try
      CodeRatchet.ensure_tools(dir; tools=["NoSuchPackageForCodeRatchet"])
      nothing
    catch e
      e
    end
    @test err isa ErrorException
    @test occursin("could not install NoSuchPackageForCodeRatchet", err.msg)
    @test !isfile(joinpath(dir, "Manifest.toml"))
    # A good one creates the environment once and finds it afterwards.
    @test CodeRatchet.ensure_tools(dir; tools=["Dates"]) == dir
    @test isfile(joinpath(dir, "Manifest.toml"))
    stamp = mtime(joinpath(dir, "Manifest.toml"))
    @test CodeRatchet.ensure_tools(dir; tools=["Dates"]) == dir
    @test mtime(joinpath(dir, "Manifest.toml")) == stamp
    @test endswith(CodeRatchet.tools_environment(), joinpath("environments", "coderatchet"))
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
