const COMPLEXITY_METRICS = (
  cyclomatic=CyclomaticComplexity(),
  cognitive=CognitiveComplexity(),
  arguments=ArgumentCountComplexity(),
)

"""
    complexity(target=pwd(); by=:cyclomatic, over=1, paths=["src", "ext"])

Every definition ranked by one complexity number, highest first.

`by` is `:cyclomatic`, `:cognitive` or `:arguments`. `over` hides definitions
below that value; it is a display filter, not a threshold anything fails on.
`target` is a package module or a directory.

Pure syntax: loads nothing under measurement and takes about a second.
"""
function complexity(
  target=pwd(); by::Symbol=:cyclomatic, over::Integer=1, paths=["src", "ext"]
)
  haskey(COMPLEXITY_METRICS, by) || throw(
    ArgumentError(
      "by must be one of $(join(repr.(keys(COMPLEXITY_METRICS)), ", ")); got $(repr(by))"
    ),
  )
  root = package_root(target)
  items = Finding[]
  for rel in source_files(root, paths)
    measured = measure_file(COMPLEXITY_METRICS[by], joinpath(root, rel))
    for fn in measured.functions
      fn.value >= over || continue
      push!(items, Finding(rel, fn.line, String(fn.name), fn.value, string(by)))
    end
  end
  return ranked("complexity ($by)", items)
end
