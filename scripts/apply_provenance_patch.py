from pathlib import Path


def replace_once(path, old, new):
    path = Path(path)
    text = path.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected one anchor, found {count}")
    path.write_text(text.replace(old, new))


replace_once(
    "src/CodeRatchet.jl",
    '''provenance(::Metric, ::AbstractString) = Dict{String,Any}()\n\n"""\n    entry_failures(metric, root, paths, rows) -> Vector{String}\n''',
    '''provenance(::Metric, ::AbstractString) = Dict{String,Any}()\n\n"""\n    metric_schema(metric) -> Int\n\nVersion of the metric's measurement semantics. Increment it when the same\nconfiguration would produce numbers with a different meaning.\n"""\nmetric_schema(::Metric) = 1\n\n"""\n    measurement_provenance(metric, root) -> Dict{String,Any}\n\nComplete semantic identity of one measurement. Every field except `commit`\nbinds: a baseline is comparable only when the semantic key set and values agree.\n"""\nfunction measurement_provenance(metric::Metric, root::AbstractString)\n  result = copy(provenance(metric, root))\n  result["schema"] = metric_schema(metric)\n  result["binding"] = collect(binding(metric))\n  result["direction"] = [string(direction(metric, key)) for key in binding(metric)]\n  return result\nend\n\n"""\n    entry_failures(metric, root, paths, rows) -> Vector{String}\n''',
)

replace_once(
    "src/CodeRatchet.jl",
    '''  for (key, value) in sort(collect(provenance(metric, root)); by=first)\n    println(io, key, " = ", tomlvalue(value))\n  end\n  println(io, "binding = ", tomlvalue(collect(binding(metric))))\n''',
    '''  for (key, value) in sort(collect(measurement_provenance(metric, root)); by=first)\n    println(io, key, " = ", tomlvalue(value))\n  end\n''',
)

replace_once(
    "src/CodeRatchet.jl",
    '''function provenance_failures(\n  metric::Metric, recorded::Dict{String,Any}, root::AbstractString\n)\n  isempty(recorded) && return String[]\n  bad = String[]\n  for (key, value) in sort(collect(provenance(metric, root)); by=first)\n    key == "commit" && continue\n    haskey(recorded, key) || continue\n    recorded[key] == value && continue\n    push!(\n      bad,\n      "provenance moved under the baseline: $key was $(repr(recorded[key])), " *\n      "now $(repr(value)). Refresh the baseline in the same commit that moved the tool.",\n    )\n  end\n  return bad\nend\n''',
    '''function provenance_failures(\n  metric::Metric, recorded::Dict{String,Any}, root::AbstractString\n)\n  expected = measurement_provenance(metric, root)\n  comparable_keys(table) = Set(k for k in keys(table) if k != "commit")\n  expected_keys = comparable_keys(expected)\n  recorded_keys = comparable_keys(recorded)\n  bad = String[]\n\n  for key in sort!(collect(setdiff(expected_keys, recorded_keys)))\n    push!(\n      bad,\n      "provenance missing from the baseline: $key is now required as " *\n      "$(repr(expected[key])). Refresh the baseline in the same commit that moved the tool.",\n    )\n  end\n  for key in sort!(collect(setdiff(recorded_keys, expected_keys)))\n    push!(\n      bad,\n      "stale provenance in the baseline: $key = $(repr(recorded[key])) is no longer " *\n      "part of this metric. Refresh the baseline in the same commit that moved the tool.",\n    )\n  end\n  for key in sort!(collect(intersect(expected_keys, recorded_keys)))\n    recorded[key] == expected[key] && continue\n    push!(\n      bad,\n      "provenance moved under the baseline: $key was $(repr(recorded[key])), " *\n      "now $(repr(expected[key])). Refresh the baseline in the same commit that moved the tool.",\n    )\n  end\n  return bad\nend\n''',
)

replace_once(
    "src/complexity.jl",
    '''using CodeComplexity:\n  ArgumentCountComplexity, CognitiveComplexity, CyclomaticComplexity, measure_file\n''',
    '''import CodeComplexity\nusing CodeComplexity:\n  ArgumentCountComplexity, CognitiveComplexity, CyclomaticComplexity, measure_file\n''',
)

replace_once(
    "src/complexity.jl",
    '''    "tool" => "CodeComplexity",\n    # Changed when the count of definitions above threshold was added. An older\n''',
    '''    "tool" => "CodeComplexity",\n    "version" => string(Base.pkgversion(CodeComplexity)),\n    # Changed when the count of definitions above threshold was added. An older\n''',
)

replace_once(
    "ext/CodeRatchetJETExt.jl",
    '''    "metric" => "jet",\n    "attribution" => "deepest_repository_frame",\n''',
    '''    "metric" => "jet",\n    "tool" => "JET",\n    "version" => string(Base.pkgversion(JET)),\n    "attribution" => "deepest_repository_frame",\n''',
)

replace_once(
    "test/runtests.jl",
    '''  @testset "the ratchet" begin\n''',
    '''  @testset "semantic provenance is exact" begin\n    root = gitrepo(Dict("src/a.jl" => "f() = 1\\n"); rulings=SRC_ONLY)\n    metric = Fake()\n    expected = CodeRatchet.measurement_provenance(metric, root)\n\n    @test expected["schema"] == 1\n    @test expected["binding"] == ["bind"]\n    @test expected["direction"] == ["down"]\n    @test isempty(CodeRatchet.provenance_failures(metric, copy(expected), root))\n\n    missing = copy(expected)\n    delete!(missing, "schema")\n    @test any(\n      msg -> occursin("provenance missing", msg),\n      CodeRatchet.provenance_failures(metric, missing, root),\n    )\n\n    stale = copy(expected)\n    stale["old_schema"] = 1\n    @test any(\n      msg -> occursin("stale provenance", msg),\n      CodeRatchet.provenance_failures(metric, stale, root),\n    )\n\n    moved = copy(expected)\n    moved["direction"] = ["up"]\n    @test any(\n      msg -> occursin("provenance moved", msg),\n      CodeRatchet.provenance_failures(metric, moved, root),\n    )\n\n    with_commit = copy(expected)\n    with_commit["commit"] = "an older source tree"\n    @test isempty(CodeRatchet.provenance_failures(metric, with_commit, root))\n\n    rendered = CodeRatchet.render_baseline(metric, Dict("src/a.jl" => fake(1, 2)), root)\n    @test occursin("schema = 1", rendered)\n    @test occursin("binding = [\\\"bind\\\"]", rendered)\n    @test occursin("direction = [\\\"down\\\"]", rendered)\n  end\n\n  @testset "the ratchet" begin\n''',
)
