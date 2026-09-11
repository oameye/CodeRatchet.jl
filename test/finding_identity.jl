# Finding-level ratchets: aggregate counts are necessary but not sufficient.
# A different finding may not replace an old one merely because the count stays
# flat (or even falls).

using Test
using CodeRatchet

struct FindingFake <: CodeRatchet.Metric
  rows::Dict{String,CodeRatchet.Row}
end

CodeRatchet.metric_name(::FindingFake) = "finding_fake"
CodeRatchet.binding(::FindingFake) = ("reviewed",)
CodeRatchet.row_numbers(::FindingFake) = ("raw", "reviewed")
CodeRatchet.finding_binding(::FindingFake) = "reviewed"
function CodeRatchet.measure(metric::FindingFake, ::AbstractString; dir::AbstractString="")
  return deepcopy(metric.rows)
end

function finding_row(findings; raw=length(findings), reviewed=length(findings))
  return CodeRatchet.Row(
    Dict("raw" => Int(raw), "reviewed" => Int(reviewed)),
    String[String(f) for f in findings],
  )
end

@testset "finding identity ratchet" begin
  base = Dict("src/a.jl" => finding_row(["A", "B"]))

  @testset "identity replacement fails at equal reviewed count" begin
    current = Dict("src/a.jl" => finding_row(["A", "C"]))
    numeric, _, _, renames = CodeRatchet.ratchet(FindingFake(current), current, base)
    @test isempty(numeric)
    finding = CodeRatchet.finding_violations(FindingFake(current), current, base, renames)
    @test length(finding) == 1
    @test only(finding).identity == "C"
    @test only(finding).from == 0
    @test only(finding).to == 1
  end

  @testset "a new identity fails even when aggregate debt falls" begin
    current = Dict("src/a.jl" => finding_row(["C"]))
    numeric, _, _, renames = CodeRatchet.ratchet(FindingFake(current), current, base)
    @test isempty(numeric)
    finding = CodeRatchet.finding_violations(FindingFake(current), current, base, renames)
    @test length(finding) == 1
    @test only(finding).identity == "C"
  end

  @testset "duplicate multiplicity is binding" begin
    old = Dict("src/a.jl" => finding_row(["A"]))
    current = Dict("src/a.jl" => finding_row(["A", "A"]))
    _, _, _, renames = CodeRatchet.ratchet(FindingFake(current), current, old)
    finding = CodeRatchet.finding_violations(FindingFake(current), current, old, renames)
    @test length(finding) == 1
    @test only(finding).identity == "A"
    @test only(finding).from == 1
    @test only(finding).to == 2
  end

  @testset "removing findings is quiet" begin
    current = Dict("src/a.jl" => finding_row(["A"]))
    numeric, _, _, renames = CodeRatchet.ratchet(FindingFake(current), current, base)
    @test isempty(numeric)
    @test isempty(
      CodeRatchet.finding_violations(FindingFake(current), current, base, renames)
    )
  end

  @testset "finding order is not identity" begin
    current = Dict("src/a.jl" => finding_row(["B", "A"]))
    _, _, _, renames = CodeRatchet.ratchet(FindingFake(current), current, base)
    @test isempty(
      CodeRatchet.finding_violations(FindingFake(current), current, base, renames)
    )
  end

  @testset "an exact rename carries finding history" begin
    current = Dict("src/b.jl" => finding_row(["A", "B"]))
    numeric, new_files, dead_files, renames = CodeRatchet.ratchet(
      FindingFake(current), current, base
    )
    @test isempty(numeric)
    @test isempty(new_files)
    @test isempty(dead_files)
    @test renames == Dict("src/b.jl" => "src/a.jl")
    @test isempty(
      CodeRatchet.finding_violations(FindingFake(current), current, base, renames)
    )
  end

  @testset "same counts but different findings are not a rename" begin
    current = Dict("src/b.jl" => finding_row(["A", "C"]))
    _, new_files, dead_files, renames = CodeRatchet.ratchet(
      FindingFake(current), current, base
    )
    @test isempty(renames)
    @test new_files == ["src/b.jl"]
    @test dead_files == ["src/a.jl"]
  end

  @testset "a new file must enter without reviewed findings" begin
    metric = FindingFake(Dict("src/new.jl" => finding_row(["A"])))
    bad = CodeRatchet.entry_failures(metric, "/repo", ["src/new.jl"], metric.rows)
    @test length(bad) == 1
    @test occursin("enters with 1 reviewed finding", only(bad))

    clean = FindingFake(Dict("src/new.jl" => finding_row(String[])))
    @test isempty(CodeRatchet.entry_failures(clean, "/repo", ["src/new.jl"], clean.rows))
  end

  @testset "finding-aware baselines round-trip deterministically" begin
    root = gitrepo(Dict("src/a.jl" => "f() = 1\n"); rulings=SRC_ONLY)
    dir = CodeRatchet.ratchet_dir(root)
    metric = FindingFake(Dict("src/a.jl" => finding_row(["B", "A", "A"])))
    text = CodeRatchet.render_baseline(metric, metric.rows, root)
    @test occursin("findings = [\"A\", \"A\", \"B\"]", text)
    write(joinpath(dir, "finding_fake_baseline.toml"), text)
    back, _ = CodeRatchet.read_baseline(metric, dir)
    @test back == metric.rows
  end

  @testset "the reviewed count and finding multiset must agree" begin
    root = gitrepo(Dict("src/a.jl" => "f() = 1\n"); rulings=SRC_ONLY)
    bad = FindingFake(Dict("src/a.jl" => finding_row(["A"]; reviewed=2)))
    @test_throws ErrorException CodeRatchet.render_baseline(bad, bad.rows, root)
  end

  @testset "plain refresh cannot absorb a new finding" begin
    root = gitrepo(Dict("src/a.jl" => "f() = 1\n"); rulings=SRC_ONLY)
    first_metric = FindingFake(Dict("src/a.jl" => finding_row(["A"])))
    CodeRatchet.refresh(first_metric, root)

    changed = FindingFake(Dict("src/a.jl" => finding_row(["B"])))
    @test_throws ErrorException CodeRatchet.refresh(changed, root)
    CodeRatchet.refresh(changed, root; accept_change=true)
    @test CodeRatchet.ok(CodeRatchet.check(changed, root))
  end
  @testset "finding violations render and provenance helper branches are covered" begin
    violation = CodeRatchet.FindingViolation("src/a.jl", "A|B", 0, 1)
    @test occursin("multiplicity 0 -> 1", sprint(show, violation))
    @test occursin("A\\|B", CodeRatchet.finding_table([violation]))

    root = gitrepo(Dict("src/a.jl" => "f() = 1\n"); rulings=SRC_ONLY)
    baseline = FindingFake(Dict("src/a.jl" => finding_row(["A"])))
    CodeRatchet.refresh(baseline, root)
    changed = FindingFake(Dict("src/a.jl" => finding_row(["B"])))
    report = CodeRatchet.check(changed, root)
    summary = CodeRatchet.check_summary(report)
    @test summary !== nothing
    @test occursin("new finding", summary)
    @test CodeRatchet.check_summary(CodeRatchet.check(baseline, root)) === nothing
    @test CodeRatchet.do_check(changed, root, CodeRatchet.ratchet_dir(root)) == 1

    dir = CodeRatchet.ratchet_dir(root)
    @test isempty(
      CodeRatchet.refresh_provenance_failures(
        baseline, nothing, Dict{String,Any}(), root, dir
      ),
    )
    rows, recorded = CodeRatchet.read_baseline(baseline, dir)
    @test rows !== nothing
    @test isempty(
      CodeRatchet.refresh_provenance_failures(baseline, rows, recorded, root, dir)
    )
  end
  @testset "Row convenience construction preserves hash equality" begin
    row = CodeRatchet.Row("raw" => 0, "reviewed" => 0)
    same = CodeRatchet.Row(Dict("raw" => 0, "reviewed" => 0))
    @test row == same
    @test hash(row) == hash(same)
  end
end
