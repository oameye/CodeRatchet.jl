"""
    Lsp()

JETLS diagnostics per file, ratcheted on the **reviewed** count.

JETLS reports what JET does not. JET analyses inference; JETLS analyses
lowering, and finds undefined globals, unused imports and arguments, dead
branches and unsorted name lists. The two overlap almost nowhere, so a
repository running both is not paying twice for one answer.

This metric shells out to the `jetls` binary and parses its output. There is no
Julia dependency to add, and no version of JETLS to resolve against the package
under measurement.
"""
struct Lsp <: Metric end

metric_name(::Lsp) = "lsp"
binding(::Lsp) = ("reviewed",)
row_numbers(::Lsp) = ("raw", "reviewed")
dismissal_section(::Lsp) = "lsp_dismissal"

"""
    Diagnostic

One reported problem: where it is, how loud it is, and what kind it is.
"""
struct Diagnostic
  path::String
  line::Int
  severity::String
  code::String
  message::String
end

"""
    lsp_settings(rulings) -> NamedTuple

The `[lsp]` block: the entry files, the binary, and the severity floor.

`skip_full_analysis` defaults to **false**, against the habit the flag invites.
Skipping the full analysis leaves JETLS without the module a file belongs to,
so its imports read as unused and its macros read as undefined. Measured on a
nine-file package: with the flag, one file analysed and fourteen diagnostics of
which nearly all were false; without it, nine files in thirty seconds and seven
diagnostics, all real. The flag is for auditing Base, where analysing
everything is not an option.
"""
function lsp_settings(rulings::Rulings)
  block = get(rulings.raw, "lsp", Dict{String,Any}())
  entry = String[String(p) for p in get(block, "entry", String[])]
  isempty(entry) && error(
    "the lsp metric needs a [lsp] block in $RULINGS naming `entry`, the file or " *
    "files to hand to `jetls check`. For a package that is usually src/<Package>.jl.",
  )
  return (
    entry=entry,
    binary=String(get(block, "binary", "jetls")),
    severity=String(get(block, "severity", "hint")),
    skip_full_analysis=Bool(get(block, "skip_full_analysis", false)),
  )
end

function measurement_configuration(::Lsp, rulings::Rulings)
  settings = lsp_settings(rulings)
  return Dict{String,Any}(
    "version" => jetls_version(settings.binary),
    "severity" => settings.severity,
    "full_analysis" => !settings.skip_full_analysis,
    "entry" => sort(settings.entry),
  )
end

function provenance(::Lsp, root::AbstractString)
  return Dict{String,Any}(
    "metric" => "lsp", "tool" => "jetls", "commit" => short_commit(root)
  )
end

"""
    jetls_version(binary) -> String

The tool's own version string, pinned in provenance.

JETLS is versioned by date and adds diagnostics between releases, so a new
version can raise the count without a line of the repository changing. Binding
on the version turns that into a refresh with a visible reason rather than a
red gate with none.
"""
function jetls_version(binary::AbstractString)
  Sys.which(binary) === nothing && error(
    "`$binary` is not on PATH. Install it with\n" *
    "  julia -e 'using Pkg; Pkg.Apps.add(; url=\"https://github.com/aviatesk/JETLS.jl\", rev=\"release\")'\n" *
    "and put ~/.julia/bin on PATH.",
  )
  out = try
    read(pipeline(ignorestatus(`$binary version`); stderr=devnull), String)
  catch
    return "unknown"
  end
  # `jetls --help` prints "VERSION: <date>"; `jetls version` prints
  # "jetls version <date>, julia version <v>". Take the whole of the latter:
  # JETLS results depend on the Julia it runs under, so both belong in
  # provenance, and a baseline is not comparable across either.
  for pattern in (r"^jetls version .+$"m, r"VERSION:\s*(\S+)")
    m = match(pattern, out)
    m === nothing && continue
    return isempty(m.captures) ? String(strip(m.match)) : String(captured(m, 1))
  end
  return String(strip(out))
end

# --- parsing ----------------------------------------------------------------

"""
    captured(m, i) -> SubString

Group `i` of a match, refusing to carry its optionality any further.

`RegexMatch.captures` is a `Vector{Union{Nothing,SubString{String}}}`, because
a group need not participate in a match. Every group these patterns read is
mandatory, so the `nothing` is unreachable, but the *type* says otherwise and
`String(nothing)` is a MethodError: JET reported ten of them here. `something`
narrows the union and throws a named error rather than a method error if a
pattern is ever edited to make a group optional.
"""
captured(m::RegexMatch, i::Int) = something(m.captures[i])

# A diagnostic's location is its own comment line; the finding itself ends with
# a `[severity:code]` tag. Anchoring on the tag rather than on the box-drawing
# gutter keeps the parse independent of --context-lines.
const LSP_HEADER = r"^#\s*@\s*(.+?):(\d+),(\d+)\s*$"
const LSP_TAG = r"\[(error|warn|warning|info|information|hint):([^\]]+)\]\s*$"
const LSP_TOTAL = r"^#\s*Found\s+(\d+)\s+diagnostic"

"""
    parse_diagnostics(text, root) -> (Vector{Diagnostic}, Int)

The diagnostics, and the total JETLS said it found.

Both are returned so the caller can compare them. A parser reading a
human-formatted report is the fragile part of this metric, and the tool
conveniently states its own total: when the two disagree the format has moved
and the numbers are not to be trusted.
"""
function parse_diagnostics(text::AbstractString, root::AbstractString)
  found = Diagnostic[]
  claimed = -1
  path, line = "", 0
  for raw in eachline(IOBuffer(text))
    total = match(LSP_TOTAL, raw)
    if total !== nothing
      claimed = parse(Int, captured(total, 1))
      continue
    end
    header = match(LSP_HEADER, raw)
    if header !== nothing
      path = relative_to(String(captured(header, 1)), root)
      line = parse(Int, captured(header, 2))
      continue
    end
    tag = match(LSP_TAG, raw)
    tag === nothing && continue
    isempty(path) && continue
    message = strip(replace(raw[1:(tag.offset - 1)], r"^[^\w`\"']*" => ""))
    push!(
      found,
      Diagnostic(
        path, line, String(captured(tag, 1)), String(captured(tag, 2)), String(message)
      ),
    )
  end
  return found, claimed
end

"""
    dismissed(diagnostic, rulings) -> Bool

Whether a human has ruled this diagnostic a non-defect.

A `[[lsp_dismissal]]` may name a `code`, a `severity` and a `pattern` over the
message. Every field present must match, so naming more of them narrows the
dismissal rather than widening it.
"""
function dismissed(diagnostic::Diagnostic, rulings::Rulings)
  for ruling in get(rulings.raw, "lsp_dismissal", Dict[])
    haskey(ruling, "reason") || error("every [[lsp_dismissal]] needs a `reason`")
    any(k -> haskey(ruling, k), ("code", "severity", "pattern"))::Bool || error(
      "an [[lsp_dismissal]] with no `code`, `severity` or `pattern` would dismiss " *
      "every diagnostic; name at least one",
    )
    haskey(ruling, "code") && String(ruling["code"]) != diagnostic.code && continue
    haskey(ruling, "severity") &&
      String(ruling["severity"]) != diagnostic.severity &&
      continue
    haskey(ruling, "pattern") &&
      !occursin(Regex(String(ruling["pattern"])), diagnostic.message) &&
      continue
    return true
  end
  return false
end

"""
    run_jetls(root, settings) -> String

Run `jetls check` and hand back its output.

A nonzero exit is the normal case, not a failure: `jetls check` exits 1 whenever
it finds anything at or above its exit severity, which is most runs on most
repositories.
"""
function run_jetls(root::AbstractString, settings)
  jetls_version(settings.binary)
  flags = ["--context-lines=0", "--progress=none", "--show-severity=$(settings.severity)"]
  settings.skip_full_analysis && push!(flags, "--skip-full-analysis")
  cmd = Cmd(`$(settings.binary) check $flags $(settings.entry)`; dir=root)
  return read(pipeline(ignorestatus(cmd); stderr=devnull), String)
end

function measure(::Lsp, root::AbstractString; dir::AbstractString=ratchet_dir(root))
  rulings = read_rulings(dir)
  settings = lsp_settings(rulings)
  found, claimed = parse_diagnostics(run_jetls(root, settings), root)
  claimed >= 0 &&
    length(found) != claimed &&
    error(
      "parsed $(length(found)) diagnostics but jetls reported $claimed. Its output " *
      "format has moved; the numbers from this run are not comparable to a baseline.",
    )

  rows = Dict{String,Row}(
    rel => Row(Dict("raw" => 0, "reviewed" => 0)) for
    rel in scoped_files(root, rulings.scope)
  )
  for diagnostic in found
    haskey(rows, diagnostic.path) || continue
    numbers = rows[diagnostic.path].numbers
    numbers["raw"] += 1
    dismissed(diagnostic, rulings) || (numbers["reviewed"] += 1)
  end
  return rows
end

"""
    lsp_report(root; dir) -> Vector{String}

Every undismissed diagnostic, one line each, for a person about to fix them.
"""
function lsp_report(root::AbstractString=pwd(); dir::AbstractString=ratchet_dir(root))
  rulings = read_rulings(dir)
  found, _ = parse_diagnostics(run_jetls(root, lsp_settings(rulings)), root)
  keep = [d for d in found if !dismissed(d, rulings)]
  sort!(keep; by=d -> (d.path, d.line))
  return ["$(d.path):$(d.line): [$(d.severity):$(d.code)] $(d.message)" for d in keep]
end
