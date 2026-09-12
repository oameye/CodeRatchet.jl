# The Lsp metric: JETLS diagnostics, parsed from the tool's own report.

using Test
using CodeRatchet
using CodeRatchet: Diagnostic, Lsp, dismissed, lsp_settings, parse_diagnostics, read_rulings

# A real `jetls check --context-lines=0` report, trimmed. Real output rather
# than an invented shape: the parser's whole job is to survive this format.
const JETLS_OUTPUT = """
# Analyzed 9 files in 11.67s
# Found 3 diagnostics in 2 files (1 warning, 1 info, 1 hint)

# @ src/Pkg.jl:24,1
export B, A
└──────────┘ ── Names are not sorted alphabetically [hint:lowering/unsorted-import-names]

# @ src/inner.jl:79,33
function project(operator)
#                └──────┘ ── Unused argument `operator` [info:lowering/unused-argument]

# @ src/inner.jl:240,1
if maybe
└──────┘ ── non-boolean `Missing` found in boolean context [warn:inference/type-error/non-bool-cond]
"""

const LSP_RULINGS = """
[scope]
measure = ["src/"]

[lsp]
entry = ["src/Pkg.jl"]

[[lsp_dismissal]]
code = "lowering/unsorted-import-names"
pattern = "Names are not sorted"
reason = "Export order groups by concept here, not alphabetically."
"""

@testset "the Lsp metric" begin
  @testset "parsing" begin
    found, claimed = parse_diagnostics(JETLS_OUTPUT, "/repo")

    @testset "every diagnostic is found" begin
      @test claimed == 3
      @test length(found) == 3
    end

    @testset "location comes from the header, not the gutter" begin
      @test found[1].path == "src/Pkg.jl"
      @test found[1].line == 24
      @test found[2].path == "src/inner.jl"
      @test found[2].line == 79
      @test found[3].line == 240
    end

    @testset "severity and code come from the tag" begin
      @test found[1].severity == "hint"
      @test found[1].code == "lowering/unsorted-import-names"
      @test found[2].severity == "info"
      @test found[3].severity == "warn"
      @test found[3].code == "inference/type-error/non-bool-cond"
    end

    @testset "the message drops the gutter and keeps the text" begin
      @test found[1].message == "Names are not sorted alphabetically"
      @test found[2].message == "Unused argument `operator`"
      @test found[3].message == "non-boolean `Missing` found in boolean context"
    end

    @testset "an absolute path is made repository-relative" begin
      text = replace(JETLS_OUTPUT, "# @ src/" => "# @ /repo/src/")
      again, _ = parse_diagnostics(text, "/repo")
      @test first(again).path == "src/Pkg.jl"
    end

    @testset "a report with no diagnostics parses to none" begin
      empty, total = parse_diagnostics(
        "# Analyzed 9 files in 1.0s\n# Found 0 diagnostics in 0 files\n", "/repo"
      )
      @test isempty(empty)
      @test total == 0
    end
  end

  @testset "dismissals" begin
    rulings = read_rulings(
      dirname(
        (
          root=gitrepo(Dict("src/Pkg.jl" => "module Pkg end"); rulings=LSP_RULINGS);
          joinpath(root, "code_ratchet", "rulings.toml")
        ),
      ),
    )
    hint = Diagnostic(
      "src/Pkg.jl", 24, "hint", "lowering/unsorted-import-names", "Names are not sorted"
    )
    unused = Diagnostic(
      "src/inner.jl", 79, "info", "lowering/unused-argument", "Unused argument `operator`"
    )

    @testset "a semantic dismissal matching code and message holds" begin
      @test dismissed(hint, rulings)
    end

    @testset "an undismissed diagnostic stands" begin
      @test !dismissed(unused, rulings)
    end
  end

  @testset "recording keeps reviewed findings in the row" begin
    root = gitrepo(Dict("src/Pkg.jl" => "module Pkg end"); rulings=LSP_RULINGS)
    rulings = read_rulings(joinpath(root, "code_ratchet"))
    hint = Diagnostic(
      "src/Pkg.jl", 24, "hint", "lowering/unsorted-import-names", "Names are not sorted"
    )
    unused = Diagnostic(
      "src/inner.jl", 79, "info", "lowering/unused-argument", "Unused argument `operator`"
    )
    row = CodeRatchet.Row(Dict("raw" => 0, "reviewed" => 0))
    CodeRatchet.record_diagnostic!(row, unused, rulings)
    @test row.numbers == Dict("raw" => 1, "reviewed" => 1)
    @test row.findings == [CodeRatchet.finding_identity(unused)]
    CodeRatchet.record_diagnostic!(row, hint, rulings)
    @test row.numbers == Dict("raw" => 2, "reviewed" => 1)
    @test row.findings == [CodeRatchet.finding_identity(unused)]
  end

  @testset "a dismissal narrows as more of it is named" begin
    make(body) = read_rulings(
      dirname(
        (
          root=gitrepo(Dict("src/a.jl" => "f(x) = x"); rulings=body);
          joinpath(root, "code_ratchet", "rulings.toml")
        ),
      ),
    )
    base = "[scope]\nmeasure = [\"src/\"]\n\n[lsp]\nentry = [\"src/a.jl\"]\n"
    d = Diagnostic("src/a.jl", 1, "info", "lowering/unused-argument", "Unused argument `x`")

    code_only = make(
      base * "\n[[lsp_dismissal]]\ncode = \"lowering/unused-argument\"\nreason = \"r\"\n"
    )
    @test_throws ErrorException dismissed(d, code_only)
    @test_throws ErrorException CodeRatchet.validate_lsp_dismissals(code_only)

    pattern_only = make(
      base * "\n[[lsp_dismissal]]\npattern = \"Unused argument\"\nreason = \"r\"\n"
    )
    @test dismissed(d, pattern_only)

    # Adding a field that does not match must NARROW the dismissal, never widen
    # it. A dismissal that grew as it was specified would be a trap.
    with_pattern = make(
      base *
      "\n[[lsp_dismissal]]\ncode = \"lowering/unused-argument\"\n" *
      "pattern = \"never matches this\"\nreason = \"r\"\n",
    )
    @test !dismissed(d, with_pattern)

    wrong_severity = make(
      base *
      "\n[[lsp_dismissal]]\ncode = \"lowering/unused-argument\"\n" *
      "severity = \"error\"\npattern = \"Unused argument\"\nreason = \"r\"\n",
    )
    @test !dismissed(d, wrong_severity)
  end

  @testset "a dismissal without a semantic pattern is refused" begin
    rulings = read_rulings(
      dirname(
        (
          root=gitrepo(
            Dict("src/a.jl" => "f(x) = x");
            rulings="[scope]\nmeasure = [\"src/\"]\n\n[[lsp_dismissal]]\nreason = \"r\"\n",
          );
          joinpath(root, "code_ratchet", "rulings.toml")
        ),
      ),
    )
    d = Diagnostic("src/a.jl", 1, "info", "c", "m")
    @test_throws ErrorException dismissed(d, rulings)
  end

  @testset "an empty dismissal pattern is refused" begin
    root = gitrepo(
      Dict("src/a.jl" => "f(x) = x");
      rulings="""
      [scope]
      measure = ["src/"]

      [lsp]
      entry = ["src/a.jl"]

      [[lsp_dismissal]]
      pattern = ""
      reason = "r"
      """,
    )
    rulings = read_rulings(joinpath(root, "code_ratchet"))
    @test_throws ErrorException CodeRatchet.validate_lsp_dismissals(rulings)
  end

  @testset "settings" begin
    @testset "full analysis is the default, against the flag's habit" begin
      root = gitrepo(Dict("src/Pkg.jl" => "module Pkg end"); rulings=LSP_RULINGS)
      settings = lsp_settings(read_rulings(joinpath(root, "code_ratchet")))
      @test settings.skip_full_analysis == false
      @test settings.entry == ["src/Pkg.jl"]
      @test settings.severity == "hint"
    end

    @testset "measurement configuration is semantic provenance" begin
      rulings_text = """
      [scope]
      measure = ["src/"]

      [lsp]
      entry = ["src/z.jl", "src/a.jl"]
      binary = "echo"
      severity = "warning"
      skip_full_analysis = true
      """
      root = gitrepo(Dict("src/a.jl" => "f(x) = x"); rulings=rulings_text)
      dir = joinpath(root, "code_ratchet")
      p = CodeRatchet.measurement_provenance(Lsp(), root; dir)
      @test p["tool"] == "jetls"
      @test p["version"] == "version"
      @test p["severity"] == "warning"
      @test p["full_analysis"] == false
      @test p["entry"] == ["src/a.jl", "src/z.jl"]
    end

    @testset "a missing entry list is refused" begin
      root = gitrepo(
        Dict("src/a.jl" => "f(x) = x"); rulings="[scope]\nmeasure = [\"src/\"]\n"
      )
      @test_throws ErrorException lsp_settings(read_rulings(joinpath(root, "code_ratchet")))
    end
  end

  @testset "finding identity excludes location and includes semantics" begin
    a = Diagnostic("src/a.jl", 4, "info", "lowering/unused-argument", "Unused argument `x`")
    moved = Diagnostic(
      "src/a.jl", 400, "info", "lowering/unused-argument", "Unused argument `x`"
    )
    @test CodeRatchet.finding_identity(a) == CodeRatchet.finding_identity(moved)
    @test CodeRatchet.finding_identity(a) !=
      CodeRatchet.finding_identity(Diagnostic("src/a.jl", 4, "warn", a.code, a.message))
    @test CodeRatchet.finding_identity(a) != CodeRatchet.finding_identity(
      Diagnostic("src/a.jl", 4, a.severity, "other/code", a.message)
    )
    @test CodeRatchet.finding_identity(a) != CodeRatchet.finding_identity(
      Diagnostic("src/a.jl", 4, a.severity, a.code, "Unused argument `y`")
    )
  end

  @testset "the metric's shape" begin
    @test metric_name(Lsp()) == "lsp"
    @test binding(Lsp()) == ("reviewed",)
    @test row_numbers(Lsp()) == ("raw", "reviewed")
    @test CodeRatchet.dismissal_section(Lsp()) == "lsp_dismissal"
    @test CodeRatchet.finding_binding(Lsp()) == "reviewed"
    @test CodeRatchet.metric_schema(Lsp()) == 2
  end
end
