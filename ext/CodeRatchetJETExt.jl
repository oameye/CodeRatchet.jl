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

JET reports per file, ratcheted on the **reviewed** count.

The reviewed number binds and the raw count is context. That split is what
makes a dismissal work: a dismissal covers a *class* of report, so the
fifteenth instance of an already-dismissed class must stay green. Binding on
the raw count instead would turn every new instance of a known non-defect red,
and a gate that cries wolf gets switched off.
"""
struct Inference <: CodeRatchet.Metric end

CodeRatchet.metric_name(::Inference) = "jet"
CodeRatchet.binding(::Inference) = ("reviewed",)
CodeRatchet.dismissal_section(::Inference) = "dismissal"
CodeRatchet.row_numbers(::Inference) = ("raw", "reviewed")

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

function CodeRatchet.provenance(::Inference, root::AbstractString)
  settings = jet_settings(read_rulings(ratchet_dir(root)))
  return Dict{String,Any}(
    "metric" => "jet",
    "attribution" => "deepest_repository_frame",
    "package" => settings.package,
    "load_set" => sort(settings.load),
    "commit" => CodeRatchet.short_commit(root),
  )
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
    file = String(frame.file)
    (isempty(file) || file == "top-level") && continue
    path = isabspath(file) ? file : joinpath(root, file)
    isfile(path) || continue
    rel = replace(relpath(path, root), '\\' => '/')
    startswith(rel, "..") && continue
    return rel
  end
  return ""
end

"""
    dismissed(report, rulings) -> Bool

Whether a human has ruled this class of report a non-defect.

A `[[dismissal]]` may name a `class` (the report type) and a `pattern` (a
regex over the rendered message). Every field present must match, so a
dismissal narrows rather than widens as you specify more of it.
"""
function dismissed(report, rulings::Rulings)
  class = string(nameof(typeof(report)))
  message = sprint(show, report)
  for ruling in get(rulings.raw, "dismissal", Dict[])
    haskey(ruling, "reason") || error("every [[dismissal]] needs a `reason`")
    if haskey(ruling, "class") && String(ruling["class"]) != class
      continue
    end
    if haskey(ruling, "pattern") && !occursin(Regex(String(ruling["pattern"])), message)
      continue
    end
    haskey(ruling, "class") ||
      haskey(ruling, "pattern") ||
      error(
        "a [[dismissal]] with neither `class` nor `pattern` would dismiss every " *
        "report; name at least one",
      )
    return true
  end
  return false
end

function CodeRatchet.measure(
  ::Inference, root::AbstractString; dir::AbstractString=ratchet_dir(root)
)
  rulings = read_rulings(dir)
  settings = jet_settings(rulings)

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
    numbers = rows[rel].numbers
    numbers["raw"] += 1
    dismissed(report, rulings) || (numbers["reviewed"] += 1)
  end
  return rows
end

end # module CodeRatchetJETExt
