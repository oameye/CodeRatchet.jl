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
    "src/CodeRatchet.jl",
    '''  report = check(metric, root; dir)\n  if !accept_change && !isempty(report.violations)\n    error(refuse_rise(metric_name(metric), report.violations))\n  end\n  isempty(report.unparsable) || error(\n''',
    '''  report = check(metric, root; dir)\n  human_rulings = ruling_failures(metric, root)\n  isempty(human_rulings) || error(\n    "refresh refused: fix invalid rulings before changing a generated baseline: " *\n    join(human_rulings, "; "),\n  )\n\n  baseline, recorded = read_baseline(metric, dir)\n  provenance_bad =\n    baseline === nothing || isempty(baseline) ? String[] : provenance_failures(metric, recorded, root)\n  if !accept_change && !isempty(provenance_bad)\n    error(\n      "refresh refused: this baseline was measured under incompatible provenance. " *\n      "Review the semantic/tool change, then re-run with --accept-change to migrate it deliberately. " *\n      join(provenance_bad, "; "),\n    )\n  end\n  if !accept_change && !isempty(report.violations)\n    error(refuse_rise(metric_name(metric), report.violations))\n  end\n  isempty(report.unparsable) || error(\n''',
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
    "src/init.jl",
    '''function ratchet_project(identity)\n  io = IOBuffer()\n''',
    '''function exact_git_revision(rev::AbstractString)\n  return occursin(r"^[0-9a-f]{40}([0-9a-f]{24})?$"i, rev)\nend\n\nfunction coderatchet_revision()\n  requested = get(ENV, "CODERATCHET_REV", "")\n  if !isempty(requested)\n    exact_git_revision(requested) || error(\n      "CODERATCHET_REV must be a full 40- or 64-hex git commit, not $(repr(requested)).",\n    )\n    return lowercase(requested)\n  end\n\n  source = Base.pathof(@__MODULE__)\n  if source !== nothing\n    root = dirname(dirname(source))\n    if ispath(joinpath(root, ".git"))\n      revision = try\n        strip(read(pipeline(Cmd(`git rev-parse HEAD`; dir=root); stderr=devnull), String))\n      catch\n        ""\n      end\n      exact_git_revision(revision) && return lowercase(revision)\n    end\n  end\n\n  project = Base.active_project()\n  if project !== nothing\n    manifest = joinpath(dirname(project), "Manifest.toml")\n    if isfile(manifest)\n      raw = TOML.parsefile(manifest)\n      deps = get(raw, "deps", Dict{String,Any}())\n      entries = get(deps, "CodeRatchet", Any[])\n      entries isa AbstractVector || (entries = Any[entries])\n      for entry in entries\n        entry isa AbstractDict || continue\n        revision = String(get(entry, "repo-rev", ""))\n        exact_git_revision(revision) && return lowercase(revision)\n      end\n    end\n  end\n\n  error(\n    "cannot derive an immutable CodeRatchet revision. Install CodeRatchet at an exact " *\n    "commit, develop it from a git checkout, or set CODERATCHET_REV to the full commit " *\n    "before running `coderatchet init`.",\n  )\nend\n\nfunction ratchet_project(identity)\n  io = IOBuffer()\n''',
)

replace_once(
    "src/init.jl",
    '''  else\n    println(\n      io,\n      "CodeRatchet = {url = \\"https://github.com/oameye/CodeRatchet.jl\\", rev = \\"main\\"}",\n    )\n    isempty(identity.name) || println(io, identity.name, " = {path = \\"..\\"}")\n  end\n''',
    '''  else\n    revision = coderatchet_revision()\n    println(\n      io,\n      "CodeRatchet = {url = \\"https://github.com/oameye/CodeRatchet.jl\\", rev = ",\n      repr(revision),\n      "}",\n    )\n    isempty(identity.name) || println(io, identity.name, " = {path = \\"..\\"}")\n  end\n''',
)

replace_once(
    "test/runtests.jl",
    '''  @testset "the ratchet" begin\n''',
    '''  @testset "semantic provenance is exact" begin\n    root = gitrepo(Dict("src/a.jl" => "f() = 1\\n"); rulings=SRC_ONLY)\n    metric = Fake()\n    expected = CodeRatchet.measurement_provenance(metric, root)\n\n    @test expected["schema"] == 1\n    @test expected["binding"] == ["bind"]\n    @test expected["direction"] == ["down"]\n    @test isempty(CodeRatchet.provenance_failures(metric, copy(expected), root))\n\n    for (key, value, needle) in (\n      ("schema", 2, "provenance moved"),\n      ("binding", ["other"], "provenance moved"),\n      ("direction", ["up"], "provenance moved"),\n    )\n      changed = copy(expected)\n      changed[key] = value\n      @test any(\n        msg -> occursin(needle, msg),\n        CodeRatchet.provenance_failures(metric, changed, root),\n      )\n    end\n\n    missing = copy(expected)\n    delete!(missing, "schema")\n    @test any(\n      msg -> occursin("provenance missing", msg),\n      CodeRatchet.provenance_failures(metric, missing, root),\n    )\n\n    stale = copy(expected)\n    stale["old_schema"] = 1\n    @test any(\n      msg -> occursin("stale provenance", msg),\n      CodeRatchet.provenance_failures(metric, stale, root),\n    )\n\n    with_commit = copy(expected)\n    with_commit["commit"] = "an older source tree"\n    @test isempty(CodeRatchet.provenance_failures(metric, with_commit, root))\n\n    rendered = CodeRatchet.render_baseline(metric, Dict("src/a.jl" => fake(1, 2)), root)\n    @test occursin("schema = 1", rendered)\n    @test occursin("binding = [\\\"bind\\\"]", rendered)\n    @test occursin("direction = [\\\"down\\\"]", rendered)\n  end\n\n  @testset "provenance migration is deliberate" begin\n    root = gitrepo(Dict("src/a.jl" => "f() = 1\\n"); rulings=SRC_ONLY)\n    metric = Complexity()\n    refresh(metric, root)\n    path = CodeRatchet.baseline_path(metric, joinpath(root, "code_ratchet"))\n    text = read(path, String)\n    write(path, replace(text, "schema = 1" => "schema = 999"))\n\n    @test_throws ErrorException refresh(metric, root)\n    refresh(metric, root; accept_change=true)\n    @test isempty(CodeRatchet.provenance_failures(\n      metric, last(read_baseline(metric, joinpath(root, "code_ratchet"))), root\n    ))\n  end\n\n  @testset "backend versions are semantic provenance" begin\n    root = gitrepo(Dict("src/a.jl" => "f() = 1\\n"); rulings=SRC_ONLY)\n    p = CodeRatchet.provenance(Complexity(), root)\n    @test p["tool"] == "CodeComplexity"\n    @test !isempty(p["version"])\n  end\n\n  @testset "the ratchet" begin\n''',
)

replace_once(
    "test/group_and_init.jl",
    '''  @testset "the generated Project.toml parses" begin\n''',
    '''  @testset "consumer scaffolding pins the exact running revision" begin\n    root = demo()\n    initialise(root)\n    raw = TOML.parsefile(joinpath(ratchet_dir(root), "Project.toml"))\n    revision = raw["sources"]["CodeRatchet"]["rev"]\n    @test CodeRatchet.exact_git_revision(revision)\n    @test revision != "main"\n  end\n\n  @testset "an explicit moving revision is refused" begin\n    withenv("CODERATCHET_REV" => "main") do\n      @test_throws ErrorException CodeRatchet.coderatchet_revision()\n    end\n  end\n\n  @testset "the generated Project.toml parses" begin\n''',
)

replace_once(
    "README.md",
    '''    uses: oameye/CodeRatchet.jl/.github/workflows/ratchet.yml@main\n''',
    '''    # Use the same immutable commit recorded in code_ratchet/Project.toml.\n    uses: oameye/CodeRatchet.jl/.github/workflows/ratchet.yml@<CodeRatchet-commit>\n''',
)
