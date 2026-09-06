# The Boxes metric: captured variables the compiler could not type.

using Test
using CodeRatchet
using CodeRatchet: Boxes, is_box_call, method_boxes, root_module, slot_name

# Three closures, chosen for what they prove rather than for coverage.
module BoxSubjects
"Mutates its own capture, so the capture must be boxed."
function counter()
  n = 0
  return () -> (n += 1; n)
end

"Reassigns after the closure is built, so the capture must be boxed."
function reassigned()
  x = 1
  g = () -> x
  x = 2
  return g()
end

"Captures without mutating, so nothing is boxed."
doubled(v) = map(x -> 2x, v)

# The textbook example from the older advice. On 1.12 the reassignment happens
# BEFORE the capture, and lowering now types the closure properly, so this does
# NOT box. Kept as a test so the day it changes back is a visible failure
# rather than a silent baseline drift.
function abmult(r::Int)
  r = -r
  return x -> x * r
end
end

boxes_of(f) = sum(method_boxes, methods(f); init=0)

@testset "the Boxes metric" begin
  @testset "detection" begin
    @testset "a closure mutating its capture is boxed" begin
      @test boxes_of(BoxSubjects.counter) == 1
    end

    @testset "a capture reassigned after the closure is built is boxed" begin
      @test boxes_of(BoxSubjects.reassigned) == 1
    end

    @testset "a closure that only reads its capture is not boxed" begin
      @test boxes_of(BoxSubjects.doubled) == 0
    end

    @testset "1.12 does not box a capture reassigned before it is captured" begin
      @test boxes_of(BoxSubjects.abmult) == 0
    end
  end

  @testset "is_box_call recognises both forms" begin
    @test is_box_call(Expr(:call, GlobalRef(Core, :Box)))
    @test is_box_call(Expr(:new, GlobalRef(Core, :Box)))
    @test is_box_call(Expr(:call, Core.Box))
    @test !is_box_call(Expr(:call, GlobalRef(Core, :Ref)))
    @test !is_box_call(Expr(:call, GlobalRef(Base, :Box)))
    @test !is_box_call(:x)
    @test !is_box_call(Expr(:call))
  end

  @testset "a submodule's methods count against its package" begin
    @test root_module(BoxSubjects) === BoxSubjects
    @test root_module(Base.Iterators) === Base
  end

  @testset "a box is named, because a count is not actionable" begin
    m = first(methods(BoxSubjects.counter))
    code = Base.uncompressed_ast(m)
    named = [
      slot_name(code, stmt.args[1]) for
      stmt in code.code if stmt isa Expr && stmt.head === :(=) && is_box_call(stmt.args[2])
    ]
    @test named == ["n"]
  end

  @testset "an unreadable method counts zero rather than failing the gate" begin
    @test method_boxes(first(methods(Base.getindex))) isa Int
  end

  @testset "the metric's shape" begin
    @test metric_name(Boxes()) == "boxes"
    @test binding(Boxes()) == ("boxes",)
    @test row_numbers(Boxes()) == ("boxes",)
    @test CodeRatchet.dismissal_section(Boxes()) == ""
  end

  # Lowering decides what boxes, and lowering changes between releases. A
  # baseline from another minor version is not comparable, so the version binds.
  @testset "the Julia version is part of provenance" begin
    root = gitrepo(
      Dict("src/a.jl" => "f(x) = x");
      rulings="[scope]\nmeasure = [\"src/\"]\n\n[boxes]\npackage = \"Base\"\n",
    )
    p = CodeRatchet.provenance(Boxes(), root)
    @test p["julia"] == string(VERSION.major, ".", VERSION.minor)
    @test p["package"] == "Base"
  end

  @testset "a missing [boxes] block is refused" begin
    root = gitrepo(
      Dict("src/a.jl" => "f(x) = x"); rulings="[scope]\nmeasure = [\"src/\"]\n"
    )
    @test_throws ErrorException CodeRatchet.provenance(Boxes(), root)
  end
end
