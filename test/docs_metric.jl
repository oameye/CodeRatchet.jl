# The Docs metric: public names owing a docstring.

using Test
using CodeRatchet
using CodeRatchet:
  Docstrings, docs_candidates, docs_index, measure, refresh, check, ok, undocumented

const DOCS_RULINGS = """
[scope]
measure = ["src/"]
"""

@testset "the Docstrings metric" begin
  @testset "public means declared public" begin
    root = gitrepo(
      Dict("src/P.jl" => """
           module P
           export shown
           public stated
           using SciMLPublic: @public
           @public macroed
           include("impl.jl")
           end
           """, "src/impl.jl" => """
                shown(x) = x
                stated(x) = x
                macroed(x) = x
                hidden(x) = x
                """); rulings=DOCS_RULINGS
    )
    public, documented = docs_index(root, ["src/P.jl", "src/impl.jl"])

    @testset "an export, a public declaration and a @public all count" begin
      @test "shown" in public
      @test "stated" in public
      @test "macroed" in public
    end

    @testset "a name nothing declares is internal and out of scope" begin
      @test !("hidden" in public)
    end

    @testset "nothing here is documented" begin
      @test isempty(documented)
    end

    @testset "the undocumented count follows the definitions, not the exports" begin
      rows = measure(Docstrings(), root)
      @test rows["src/impl.jl"]["undocumented"] == 3
      @test rows["src/impl.jl"]["public"] == 3
      # The module file declares the names but defines none of them.
      @test rows["src/P.jl"]["undocumented"] == 0
    end
  end

  @testset "a docstring anywhere documents the name everywhere" begin
    # A function with methods in several files is documented once, and exports
    # live in a third place again. Per-file would report the other files as
    # owing a docstring for a name a reader can plainly look up.
    root = gitrepo(
      Dict(
        "src/P.jl" => "module P\nexport f\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n",
        "src/a.jl" => "\"The documented method.\"\nf(x::Int) = x\n",
        "src/b.jl" => "f(x::String) = x\n",
      );
      rulings=DOCS_RULINGS,
    )
    rows = measure(Docstrings(), root)
    @test rows["src/a.jl"]["undocumented"] == 0
    @test rows["src/b.jl"]["undocumented"] == 0
  end

  @testset "a bare docstring above a name documents it" begin
    root = gitrepo(
      Dict(
        "src/P.jl" => "module P\nexport f\ninclude(\"a.jl\")\nend\n",
        "src/a.jl" => "f(x::Int) = x\nf(x::String) = x\n\"Documented once.\"\nf\n",
      );
      rulings=DOCS_RULINGS,
    )
    @test measure(Docstrings(), root)["src/a.jl"]["undocumented"] == 0
  end

  @testset "undocumented names are listed, not just counted" begin
    root = gitrepo(
      Dict(
        "src/P.jl" => "module P\nexport shown, other\ninclude(\"a.jl\")\nend\n",
        "src/a.jl" => "\"Has one.\"\nshown(x) = x\nother(x) = x\n",
      );
      rulings=DOCS_RULINGS,
    )
    owed = undocumented(root)
    @test length(owed) == 1
    @test occursin("`other`", only(owed))
  end

  @testset "the gate" begin
    files = Dict(
      "src/P.jl" => "module P\nexport a\ninclude(\"impl.jl\")\nend\n",
      "src/impl.jl" => "a(x) = x\n",
    )
    root = gitrepo(files; rulings=DOCS_RULINGS)

    @testset "a fresh baseline records the debt and passes" begin
      refresh(Docstrings(), root)
      @test ok(check(Docstrings(), root))
    end

    @testset "one more undocumented public name is a violation" begin
      track!(root, "src/P.jl", "module P\nexport a, b\ninclude(\"impl.jl\")\nend\n")
      track!(root, "src/impl.jl", "a(x) = x\nb(x) = x\n")
      report = check(Docstrings(), root)
      @test !ok(report)
      @test any(v -> v.key == "undocumented" && v.from == 1 && v.to == 2, report.violations)
    end

    @testset "adding the docstring clears it" begin
      track!(root, "src/impl.jl", "a(x) = x\n\"Now documented.\"\nb(x) = x\n")
      report = check(Docstrings(), root)
      @test ok(report)
    end
  end

  # The ratio would rise when a public name is deleted; the count does not.
  @testset "deleting a public name lowers the count, it does not raise a ratio" begin
    root = gitrepo(
      Dict(
        "src/P.jl" => "module P\nexport a, b\ninclude(\"impl.jl\")\nend\n",
        "src/impl.jl" => "a(x) = x\nb(x) = x\n",
      );
      rulings=DOCS_RULINGS,
    )
    @test measure(Docstrings(), root)["src/impl.jl"]["undocumented"] == 2
    track!(root, "src/P.jl", "module P\nexport a\ninclude(\"impl.jl\")\nend\n")
    track!(root, "src/impl.jl", "a(x) = x\n")
    @test measure(Docstrings(), root)["src/impl.jl"]["undocumented"] == 1
  end

  @testset "the metric's shape" begin
    @test metric_name(Docstrings()) == "docs"
    @test binding(Docstrings()) == ("undocumented",)
    @test CodeRatchet.dismissal_section(Docstrings()) == ""
  end

  @testset "candidates rank by how many docstrings are owed" begin
    root = gitrepo(
      Dict(
        "src/P.jl" => "module P\nexport a, b, c\ninclude(\"m.jl\")\ninclude(\"o.jl\")\nend\n",
        "src/m.jl" => "a(x) = x\nb(x) = x\n",
        "src/o.jl" => "c(x) = x\n",
      );
      rulings=DOCS_RULINGS,
    )
    found = sort(docs_candidates(root); by=c -> -c.rank)
    @test first(found).path == "src/m.jl"
    @test first(found).rank == 2.0
  end
end
