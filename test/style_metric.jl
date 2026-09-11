# The Style metric: house rules as counts, held rather than demanded at zero.

using Test
using CodeRatchet
using CodeRatchet:
  NamedRule,
  PatternRule,
  Style,
  check,
  count_implicit_kwargs,
  count_underscore_names,
  count_union_nothing,
  measure,
  ok,
  parse_file,
  parse_failures,
  read_rulings,
  refresh,
  style_candidates,
  style_rules

const STYLE_RULINGS = """
[scope]
measure = ["src/"]

[style]
rules = ["union_nothing", "underscore_name", "implicit_kwarg"]
"""

"Count one rule over a source string, without a repository around it."
function count_in(fn, body::AbstractString; rel::AbstractString="src/f.jl")
  dir = mktempdir()
  path = joinpath(dir, rel)
  mkpath(dirname(path))
  write(path, body)
  return fn(CodeRatchet.FileUnderTest(rel, parse_file(dir, rel), readlines(path)))
end

@testset "the Style metric" begin
  @testset "union_nothing" begin
    @testset "counts a union with Nothing in either order" begin
      @test count_in(count_union_nothing, "f(x::Union{Nothing,Int}) = x") == 1
      @test count_in(count_union_nothing, "f(x::Union{Int,Nothing}) = x") == 1
    end

    @testset "counts it wherever the name is qualified" begin
      @test count_in(count_union_nothing, "f(x::Union{Core.Nothing,Int}) = x") == 1
      @test count_in(count_union_nothing, "f(x::Base.Union{Nothing,Int}) = x") == 1
    end

    @testset "leaves a union without Nothing alone" begin
      @test count_in(count_union_nothing, "f(x::Union{Int,String}) = x") == 0
    end

    # The metric reads syntax, and prose about the rule is not a breach of it.
    # Without this the package's own documentation would fail its own gate.
    @testset "a docstring naming the pattern is not a breach" begin
      body = """
      "Returns a Union{Nothing,Int} in the bad old days."
      f(x) = x
      """
      @test count_in(count_union_nothing, body) == 0
    end

    @testset "counts every occurrence, not every file" begin
      body = """
      struct A
        x::Union{Nothing,Int}
        y::Union{Nothing,String}
      end
      """
      @test count_in(count_union_nothing, body) == 2
    end
  end

  @testset "underscore_name" begin
    @testset "counts a leading underscore on every kind of definition" begin
      @test count_in(count_underscore_names, "_f(x) = x") == 1
      @test count_in(count_underscore_names, "function _f(x)\n  return x\nend") == 1
      @test count_in(count_underscore_names, "macro _m(x)\n  return x\nend") == 1
      @test count_in(count_underscore_names, "struct _S\n  a::Int\nend") == 1
      @test count_in(count_underscore_names, "const _K = 1") == 1
    end

    @testset "leaves an ordinary name alone" begin
      @test count_in(count_underscore_names, "f(x) = x\nconst K = 1") == 0
    end

    # A documented or macro-wrapped definition is one definition. Counting the
    # wrapper as well would double every public name in a real package.
    @testset "a wrapped definition is counted once" begin
      @test count_in(count_underscore_names, "\"doc\"\n_f(x) = x") == 1
      @test count_in(count_underscore_names, "Base.@kwdef struct _S\n  a::Int = 1\nend") ==
        1
    end

    @testset "a file named with a leading underscore counts once" begin
      @test count_in(count_underscore_names, "f(x) = x"; rel="src/_helpers.jl") == 1
    end
  end

  @testset "implicit_kwarg" begin
    @testset "counts a keyword passed with no semicolon" begin
      @test count_in(count_implicit_kwargs, "g() = f(name = 1)") == 1
    end

    @testset "leaves the explicit form alone" begin
      @test count_in(count_implicit_kwargs, "g() = f(; name = 1)") == 0
    end

    # `f(x, a = 1)` in a signature declares an optional POSITIONAL argument,
    # which the parser also represents as :kw. Counting it would flag a
    # construct that has nothing to do with keywords.
    @testset "a positional default in a signature is not a keyword" begin
      @test count_in(count_implicit_kwargs, "f(x, a = 1) = x + a") == 0
      @test count_in(count_implicit_kwargs, "function f(x, a = 1)\n  return x\nend") == 0
      @test count_in(count_implicit_kwargs, "f(x::T, a = 1) where {T} = x") == 0
    end

    @testset "a keyword declared in a signature is not a call" begin
      @test count_in(count_implicit_kwargs, "f(x; a = 1) = x + a") == 0
    end

    @testset "a call inside a default value still counts" begin
      @test count_in(count_implicit_kwargs, "f(x = g(name = 1)) = x") == 1
    end
  end

  # A defensive method is still a method, and a direct unit test is the right
  # test for one: no Julia syntax puts an Integer in a type position of a
  # Union, so nothing reachable through parse_file exercises these.
  @testset "a type position holding something unexpected is not a match" begin
    @test !CodeRatchet.is_nothing_type(42)
    @test !CodeRatchet.is_nothing_type("Nothing")
    @test !CodeRatchet.names_union(42)
    @test !CodeRatchet.names_union("Union")
  end

  # A file that does not parse measures as zero on every rule, and the gate
  # fails on it separately through parse_failures. Without that split, one
  # syntax error would read as every rule suddenly being satisfied.
  @testset "an unparsable file measures zero, and fails the gate separately" begin
    root = gitrepo(Dict("src/broken.jl" => "function oops(\n"); rulings=STYLE_RULINGS)
    # Meta.parseall does not throw here: it returns a tree carrying a parser
    # failure node. Julia 1.13 uses Expr(:incomplete, ...), while earlier
    # releases commonly used Expr(:error, ...).
    tree = parse_file(root, "src/broken.jl")
    @test tree.head === :toplevel
    @test any(a -> a isa Expr && a.head in (:error, :incomplete), tree.args)
    @test measure(Style(root), root)["src/broken.jl"]["union_nothing"] == 0
    @test parse_failures(root, ["src/broken.jl"]) == ["src/broken.jl"]
  end

  @testset "a file that cannot be read at all gives an empty tree" begin
    root = gitrepo(Dict("src/a.jl" => "f(x) = x"); rulings=STYLE_RULINGS)
    @test parse_file(root, "src/nowhere.jl") == Expr(:toplevel)
  end

  @testset "the rule set" begin
    @testset "an unknown rule name is refused" begin
      root = gitrepo(
        Dict("src/a.jl" => "f(x) = x");
        rulings="[scope]\nmeasure = [\"src/\"]\n\n[style]\nrules = [\"nope\"]\n",
      )
      @test_throws ErrorException Style(root)
    end

    # A gate that measures nothing and prints PASS is worse than no gate: it
    # reads as evidence.
    @testset "an empty rule set is refused rather than passing everything" begin
      root = gitrepo(
        Dict("src/a.jl" => "f(x) = x"); rulings="[scope]\nmeasure = [\"src/\"]\n"
      )
      @test_throws ErrorException Style(root)
    end

    @testset "two rules may not share a name" begin
      rulings = """
      [scope]
      measure = ["src/"]

      [style]
      rules = ["union_nothing"]

      [[style_pattern]]
      name = "union_nothing"
      pattern = "x"
      reason = "collides with the named rule"
      """
      root = gitrepo(Dict("src/a.jl" => "f(x) = x"); rulings)
      @test_throws ErrorException Style(root)
    end

    @testset "a pattern rule needs a reason" begin
      rulings = """
      [scope]
      measure = ["src/"]

      [[style_pattern]]
      name = "noisy"
      pattern = "println"
      """
      root = gitrepo(Dict("src/a.jl" => "f(x) = x"); rulings)
      @test_throws ErrorException Style(root)
    end

    @testset "a pattern rule counts lines, not matches" begin
      rulings = """
      [scope]
      measure = ["src/"]

      [[style_pattern]]
      name = "noisy"
      pattern = "println"
      reason = "leftover debug output"
      """
      root = gitrepo(
        Dict("src/a.jl" => "f() = (println(1); println(2))\ng() = 1\n"); rulings
      )
      rows = measure(Style(root), root)
      @test rows["src/a.jl"]["noisy"] == 1
    end
  end

  @testset "the metric's shape" begin
    root = gitrepo(Dict("src/a.jl" => "f(x) = x"); rulings=STYLE_RULINGS)
    metric = Style(root)

    @testset "every rule binds" begin
      @test Set(binding(metric)) == Set(row_numbers(metric))
      @test Set(binding(metric)) ==
        Set(["union_nothing", "underscore_name", "implicit_kwarg"])
    end

    @testset "provenance pins the full rule definitions" begin
      p = CodeRatchet.measurement_provenance(metric, root)
      @test p["rules"] ==
        ["named:implicit_kwarg", "named:underscore_name", "named:union_nothing"]

      mixed = Style([
        NamedRule("union_nothing"),
        PatternRule("noisy", r"println", "leftover debug output"),
      ])
      mixed_p = CodeRatchet.measurement_provenance(mixed, root)
      @test mixed_p["rules"] == ["named:union_nothing", "pattern:noisy:r\"println\""]
    end

    @testset "style offers no dismissal route" begin
      @test CodeRatchet.dismissal_section(metric) == ""
    end
  end

  @testset "the gate" begin
    body = "f(x::Union{Nothing,Int}) = x\n"
    root = gitrepo(Dict("src/a.jl" => body); rulings=STYLE_RULINGS)

    @testset "a fresh baseline records the debt and passes" begin
      refresh(Style(root), root)
      @test ok(check(Style(root), root))
    end

    @testset "one more breach is a violation" begin
      track!(root, "src/a.jl", body * "g(y::Union{Nothing,String}) = y\n")
      report = check(Style(root), root)
      @test !ok(report)
      @test any(
        v -> v.key == "union_nothing" && v.from == 1 && v.to == 2, report.violations
      )
    end

    @testset "removing a breach is quiet, and a refresh keeps it removed" begin
      track!(root, "src/a.jl", "f(x::Int) = x\n")
      @test ok(check(Style(root), root))
      refresh(Style(root), root)
      track!(root, "src/a.jl", body)
      @test !ok(check(Style(root), root))
    end
  end

  @testset "candidates rank by breach count" begin
    rulings = STYLE_RULINGS
    root = gitrepo(
      Dict(
        "src/many.jl" => "f(a::Union{Nothing,Int}) = a\ng(b::Union{Nothing,Int}) = b\n",
        "src/one.jl" => "h(c::Union{Nothing,Int}) = c\n",
        "src/clean.jl" => "k(d::Int) = d\n",
      );
      rulings,
    )
    found = sort(style_candidates(root); by=c -> -c.rank)
    @test first(found).path == "src/many.jl"
    @test first(found).rank == 2.0
    @test !any(c -> c.path == "src/clean.jl", found)
  end
end
