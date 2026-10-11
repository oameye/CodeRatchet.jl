"""
    Finding

One fact about one place in the code: the `file` (relative to the package
root), the `line`, what is there (`what`), a number (`value`) and a short
`detail` saying what the number counts.
"""
struct Finding
  file::String
  line::Int
  what::String
  value::Int
  detail::String
end

"""
    Findings

What a metric returns: the [`Finding`](@ref)s worst first, as an
`AbstractVector`, so `first`, `filter`, `sum` and `findall` all work.

`metric` names what was measured. The REPL display shows the top 20; index or
iterate for the rest.
"""
struct Findings <: AbstractVector{Finding}
  metric::String
  items::Vector{Finding}
end

# Largest value first, then by place, so equal values keep a stable order.
function ranked(metric::AbstractString, items::Vector{Finding})
  sort!(items; by=f -> (-f.value, f.file, f.line, f.what))
  return Findings(String(metric), items)
end

Base.size(f::Findings) = size(f.items)
Base.getindex(f::Findings, i::Int) = f.items[i]

function Base.show(io::IO, ::MIME"text/plain", f::Findings; max::Int=20)
  n = length(f)
  print(io, f.metric, ": ", n, n == 1 ? " finding" : " findings")
  n == 0 && return nothing
  shown = min(n, max)
  n > shown && print(io, ", worst ", shown)
  width = maximum(i -> ncodeunits(string(f[i].file, ":", f[i].line)), 1:shown)
  for i in 1:shown
    x = f[i]
    println(io)
    place = rpad(string(x.file, ":", x.line), width)
    print(io, "  ", place, "  ", lpad(x.value, 4), "  ", x.what)
    isempty(x.detail) || print(io, "  (", x.detail, ")")
  end
  n > shown && print(io, "\n  … ", n - shown, " more")
  return nothing
end

function Base.show(io::IO, f::Findings)
  return print(io, "Findings(", repr(f.metric), ", ", length(f), ")")
end
