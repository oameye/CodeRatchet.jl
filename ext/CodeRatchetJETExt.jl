"""
    CodeRatchetJETExt

The JET half of the gate, in an extension because it is the expensive half.

`report_package` analyses a whole package and cannot be pointed at one file, so
this metric is the entire inner loop and it costs minutes and gigabytes where
complexity and coverage cost seconds. Keeping it behind a weak dependency means
the cheap gates stay cheap to load.
"""
module CodeRatchetJETExt

using CodeRatchet: CodeRatchet, Row, Rulings, ratchet_dir, read_rulings, scoped_files
using JET: JET
using TOML: TOML

"""
    Inference()

JET reports per file, ratcheted on the **reviewed** count and reviewed finding
identities.

The reviewed number and finding multiset bind; the raw count is context. A
dismissal must name a semantic message pattern, optionally narrowed by report
class, so an unrelated future report cannot disappear merely because it shares
a broad JET report type.
"""
struct Inference <: CodeRatchet.Metric end

CodeRatchet.metric_name(::Inference) = "jet"
CodeRatchet.binding(::Inference) = ("reviewed",)
CodeRatchet.dismissal_section(::Inference) = "dismissal"
CodeRatchet.row_numbers(::Inference) = ("raw", "reviewed")
CodeRatchet.metric_schema(::Inference) = 2
CodeRatchet.finding_binding(::Inference) = "reviewed"

"""
    jet_settings(rulings) -> NamedTuple

The `[jet]` block: which package to analyse, which packages to load first, and
which modules to target.

The load set is pinned in provenance because it moves the number. Loading a
package's extension triggers changes which methods exist, so a baseline taken
with a different load set is not comparable.
"""
function jet_settings(rulings::Rulings)
  block = get(rulings.raw, "jet", Dict{String,Any}())
  package = get(block, "package", nothing)
  package === nothing && error(
    "the jet metric needs a [jet] block in rulings.toml naming `package`, " *
    "the package report_package should analyse.",
  )
  return (
    package=String(package),
    load=String[String(p) for p in get(block, "load", String[])],
    targets=String[String(m) for m in get(block, "target_modules", [package])],
  )
end

function CodeRatchet.measurement_configuration(::Inference, rulings::Rulings)
  settings = jet_settings(rulings)
  return Dict{String,Any}(
    "package" => settings.package,
    "load_set" => sort(settings.load),
    "target_modules" => sort(settings.targets),
  )
end

function CodeRatchet.provenance(::Inference, root::AbstractString)
  return Dict{String,Any}(
    "metric" => "jet",
    "tool" => "JET",
    "version" => string(Base.pkgversion(JET)),
    "attribution" => "deepest_repository_frame",
    "commit" => CodeRatchet.short_commit(root),
  )
end

function repository_frame_path(frame, root::AbstractString)
  file = String(frame.file)
  (isempty(file) || file == "top-level") && return ""
  path = isabspath(file) ? file : joinpath(root, file)
  isfile(path) || return ""
  rel = replace(relpath(path, root), '\\' => '/')
  startswith(rel, "..") && return ""
  return rel
end

"""
    attribute(report, root) -> String

The repository-relative file a report belongs to, or `""` when no frame of it
lies inside the repository.

Empty string rather than `nothing`: a repository-relative path is never empty,
so the sentinel is unambiguous and no caller has to carry a union.

The deepest matching frame wins. JET orders `vst` outermost first, so this
scans backwards: the innermost repository frame is where the problem actually
is, and attributing to the outermost would pile every report onto whichever
entry point happened to reach it.
"""
function attribute(report, root::AbstractString)
  for frame in Iterators.reverse(report.vst)
    rel = repository_frame_path(frame, root)
    isempty(rel) || return rel
  end
  return ""
end

"""
    jet_owner_identity(report) -> String

Location-free identity of the innermost enclosing MethodInstance. This keeps two
otherwise identical JET reports in different methods distinct without binding
source lines or file-system paths.
"""
function jet_owner_identity(report::JET.JETInterface.InferenceErrorReport)
  isempty(report.vst) && return "toplevel"
  return sprint(JET.show_mi, report.vst[end].linfo)
end

function jet_owner_identity(
  report::JET.JETInterface.InferenceErrorReport, root::AbstractString
)
  for frame in Iterators.reverse(report.vst)
    isempty(repository_frame_path(frame, root)) && continue
    return sprint(JET.show_mi, frame.linfo)
  end
  return jet_owner_identity(report)
end

jet_finding_identity(report) = sprint(show, report)
function jet_finding_identity(report::JET.JETInterface.InferenceErrorReport)
  return jet_owner_identity(report) * " :: " * sprint(show, report)
end
function jet_finding_identity(
  report::JET.JETInterface.InferenceErrorReport, root::AbstractString
)
  return jet_owner_identity(report, root) * " :: " * sprint(show, report)
end

function CodeRatchet.finding_identity(report::JET.JETInterface.InferenceErrorReport)
  return jet_finding_identity(report)
end

function validate_dismissal(ruling)
  haskey(ruling, "reason") || error("every [[dismissal]] needs a `reason`")
  haskey(ruling, "pattern") || error(
    "every [[dismissal]] needs a non-empty `pattern`; class-only dismissals are open-ended"
  )
  pattern = String(ruling["pattern"])
  isempty(pattern) && error("every [[dismissal]] needs a non-empty `pattern`")
  return pattern
end

function validate_dismissals(rulings::Rulings)
  for ruling in get(rulings.raw, "dismissal", Dict[])
    validate_dismissal(ruling)
  end
  return nothing
end

"""
    dismissed(report, rulings) -> Bool

Whether a human has ruled this semantic report pattern a non-defect.

Every `[[dismissal]]` needs a non-empty `pattern` regex over the finding
identity and a `reason`; `class` is optional and only narrows the match. A
class-only dismissal is refused because it would silently suppress every future
report of that JET class.
"""
function dismissed(report, rulings::Rulings)
  return dismissed(report, rulings, jet_finding_identity(report))
end

function dismissed(report, rulings::Rulings, identity::AbstractString)
  class = string(nameof(typeof(report)))
  for ruling in get(rulings.raw, "dismissal", Dict[])
    pattern = validate_dismissal(ruling)
    if haskey(ruling, "class") && String(ruling["class"]) != class
      continue
    end
    occursin(Regex(pattern), identity) || continue
    return true
  end
  return false
end

function record_report!(row::Row, report, rulings::Rulings)
  return record_report!(row, report, rulings, jet_finding_identity(report))
end

function record_report!(row::Row, report, rulings::Rulings, identity::AbstractString)
  row.numbers["raw"] += 1
  dismissed(report, rulings, identity) && return nothing
  row.numbers["reviewed"] += 1
  push!(row.findings, String(identity))
  sort!(row.findings)
  return nothing
end

function CodeRatchet.measure(
  ::Inference, root::AbstractString; dir::AbstractString=ratchet_dir(root)
)
  rulings = read_rulings(dir)
  settings = jet_settings(rulings)
  validate_dismissals(rulings)

  for name in settings.load
    Base.require(Main, Symbol(name))
  end
  mod = Base.require(Main, Symbol(settings.package))
  targets = Tuple(Base.require(Main, Symbol(name)) for name in settings.targets)

  result = JET.report_package(mod; target_modules=targets)
  reports = JET.get_reports(result)

  # Every file in scope gets a row, zeros included. A metric that only records
  # the files it found reports in cannot tell a clean file from a missing one.
  rows = Dict{String,Row}(
    rel => Row(Dict("raw" => 0, "reviewed" => 0)) for
    rel in scoped_files(root, rulings.scope)
  )
  for report in reports
    rel = attribute(report, root)
    haskey(rows, rel) || continue
    record_report!(rows[rel], report, rulings, jet_finding_identity(report, root))
  end
  return rows
end

end # module CodeRatchetJETExt
