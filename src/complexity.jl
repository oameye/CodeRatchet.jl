const COMPLEXITY_METRICS = (
  cyclomatic=CyclomaticComplexity(), cognitive=CognitiveComplexity()
)

# Parameters a call signature declares: positional and keyword, a slurp counting
# once, the function's own name and its type parameters not at all.
function parameter_count(call::Expr)
  n = 0
  for a in call.args[2:end]
    if a isa Expr && a.head === :parameters
      n += count(p -> !(p isa LineNumberNode), a.args)
    else
      a isa LineNumberNode || (n += 1)
    end
  end
  return n
end

# Argument counts read from the syntax tree here rather than from
# CodeComplexity, whose version of this metric skips a definition whose
# signature carries a return annotation: `function f(a, b)::T` and `f(a)::T = 1`.
function argument_findings(root::AbstractString, rel::AbstractString, over::Integer)
  items = Finding[]
  walk(parse_file(root, rel)) do e, line
    sig = if e.head === :function && length(e.args) >= 2
      e.args[1]
    elseif is_function_assignment(e)
      e.args[1]
    else
      return nothing
    end
    call = signature_call(sig)
    call === nothing && return nothing
    n = parameter_count(call)
    n >= over && push!(items, Finding(rel, line, defname(call), n, "arguments"))
    return nothing
  end
  return items
end

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
  by === :arguments ||
    haskey(COMPLEXITY_METRICS, by) ||
    throw(
      ArgumentError("by must be :cyclomatic, :cognitive or :arguments; got $(repr(by))")
    )
  root = package_root(target)
  items = Finding[]
  for rel in source_files(root, paths)
    if by === :arguments
      append!(items, argument_findings(root, rel, over))
      continue
    end
    measured = measure_file(COMPLEXITY_METRICS[by], joinpath(root, rel))
    for fn in measured.functions
      fn.value >= over || continue
      push!(items, Finding(rel, fn.line, String(fn.name), fn.value, string(by)))
    end
  end
  return ranked("complexity ($by)", items)
end
