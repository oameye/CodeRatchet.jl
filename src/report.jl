"""
    report(target=pwd(); n=5, io=stdout)

The fast metrics at a glance: the top `n` findings of `complexity`, `style` and
`docstrings`, plus `boxes` when `target` is a loaded module. `coverage` is left
out because it runs the test suite; call it yourself.

Returns the [`Findings`](@ref) as a `NamedTuple`, so the rest of each list is
one field away.
"""
function report(target=pwd(); n::Integer=5, io::IO=stdout)
  found = (
    complexity=complexity(target), style=style(target), docstrings=docstrings(target)
  )
  target isa Module && (found = merge(found, (boxes=boxes(target),)))
  for findings in values(found)
    show(io, MIME"text/plain"(), findings; max=Int(n))
    println(io)
  end
  return found
end
