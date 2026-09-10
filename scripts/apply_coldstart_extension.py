from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def replace_once(path, old, new):
    text = path.read_text()
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{path}: expected one match, found {count}: {old!r}")
    path.write_text(text.replace(old, new))


project = ROOT / "Project.toml"
replace_once(
    project,
    '[weakdeps]\nJET = "c3a54625-cd67-489e-a8e7-0a5a0ff4e31b"\n',
    '[weakdeps]\nJET = "c3a54625-cd67-489e-a8e7-0a5a0ff4e31b"\nPkg = "44cfe95a-1eb2-52ea-b672-e2afdf69b78f"\n',
)
replace_once(
    project,
    '[extensions]\nCodeRatchetJETExt = "JET"\n',
    '[extensions]\nCodeRatchetColdStartExt = "Pkg"\nCodeRatchetJETExt = "JET"\n',
)
replace_once(
    project,
    'JuliaSyntax = "1"\nSHA = "0.7, 1"\n',
    'JuliaSyntax = "1"\nPkg = "1.12"\nSHA = "0.7, 1"\n',
)
replace_once(
    project,
    '[extras]\nJET = "c3a54625-cd67-489e-a8e7-0a5a0ff4e31b"\nTest = "8dfed614-e22c-5e08-85e1-65c5234f0b40"\n\n[targets]\ntest = ["Test", "JET"]\n',
    '[extras]\nJET = "c3a54625-cd67-489e-a8e7-0a5a0ff4e31b"\nPkg = "44cfe95a-1eb2-52ea-b672-e2afdf69b78f"\nTest = "8dfed614-e22c-5e08-85e1-65c5234f0b40"\n\n[targets]\ntest = ["Test", "JET", "Pkg"]\n',
)

core = ROOT / "src" / "CodeRatchet.jl"
replace_once(
    core,
    'export Boxes, Complexity, Coverage, Docstrings, Lsp, Style, check, refresh\n',
    'export Boxes, Complexity, Coverage, Docstrings, Lsp, Style, check, refresh\nexport coldstart_compare, coldstart_main\n\n"""\n    coldstart_compare(base, head; kwargs...)\n\nRun the optional paired cold-start comparison. Load `Pkg` to activate the\ncold-start extension before calling this function.\n"""\nfunction coldstart_compare end\n\n"""\n    coldstart_main(args=ARGS) -> Int\n\nCommand entry point for the optional paired cold-start comparison. Load `Pkg`\nto activate the cold-start extension before calling this function.\n"""\nfunction coldstart_main end\n',
)

alljl = ROOT / "src" / "all.jl"
replace_once(alljl, 'include("coldstart.jl")\ninclude("coldstart_cli.jl")\n\n', '')

extension = ROOT / "ext" / "CodeRatchetColdStartExt.jl"
extension.write_text('''"""\n    CodeRatchetColdStartExt\n\nThe paired cold-start experiment, kept behind `Pkg` so ordinary CodeRatchet\nloading and precompilation do not pay for the timing harness.\n"""\nmodule CodeRatchetColdStartExt\n\nusing CodeRatchet: CodeRatchet, Metric, RULINGS, is_ci, read_rulings, step_summary\nimport CodeRatchet: coldstart_compare, coldstart_main\nusing TOML: TOML\n\ninclude("../src/coldstart.jl")\ninclude("../src/coldstart_cli.jl")\n\nend # module CodeRatchetColdStartExt\n''')

workflow = ROOT / ".github" / "workflows" / "coldstart.yml"
replace_once(
    workflow,
    "-e 'using CodeRatchet; exit(CodeRatchet.coldstart_main())' \\\n",
    "-e 'using Pkg, CodeRatchet; exit(CodeRatchet.coldstart_main())' \\\n",
)

readme = ROOT / "README.md"
replace_once(
    readme,
    "-e 'using CodeRatchet; exit(CodeRatchet.coldstart_main())' \\\n",
    "-e 'using Pkg, CodeRatchet; exit(CodeRatchet.coldstart_main())' \\\n",
)

test = ROOT / "test" / "coldstart_metric.jl"
text = test.read_text()
text = text.replace("using Test\nusing CodeRatchet\n", "using Test\nusing Pkg\nusing CodeRatchet\n\nconst ColdStartExt = Base.get_extension(CodeRatchet, :CodeRatchetColdStartExt)\nColdStartExt === nothing && error(\"CodeRatchet cold-start extension did not load\")\n")
text = text.replace("CodeRatchet.", "ColdStartExt.")
text = text.replace("ColdStartExt.coldstart_main", "CodeRatchet.coldstart_main")
text = text.replace("ColdStartExt.coldstart_compare", "CodeRatchet.coldstart_compare")
test.write_text(text)
