from pathlib import Path


def replace_once(path, old, new):
    path = Path(path)
    text = path.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected one anchor, found {count}")
    path.write_text(text.replace(old, new))


core = Path("src/CodeRatchet.jl")
text = core.read_text()
old = "baseline === nothing || isempty(baseline)"
count = text.count(old)
if count != 2:
    raise SystemExit(f"{core}: expected two empty-baseline guards, found {count}")
core.write_text(text.replace(old, "baseline === nothing"))

replace_once(
    "test/runtests.jl",
    '''  @testset "backend versions are semantic provenance" begin\n''',
    '''  @testset "an existing empty baseline still binds provenance" begin\n    root = gitrepo(Dict("test/t.jl" => "using Test\\n"); rulings=SRC_ONLY)\n    metric = Complexity()\n    refresh(metric, root)\n    dir = joinpath(root, "code_ratchet")\n    path = CodeRatchet.baseline_path(metric, dir)\n    text = read(path, String)\n    write(path, replace(text, "schema = 1" => "schema = 999"))\n\n    report = check(metric, root; dir)\n    @test !report.bootstrap\n    @test !ok(report)\n    @test any(msg -> occursin("provenance moved", msg), report.rulings)\n    @test_throws ErrorException refresh(metric, root; dir)\n  end\n\n  @testset "backend versions are semantic provenance" begin\n''',
)
