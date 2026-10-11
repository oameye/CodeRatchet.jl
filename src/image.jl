const IMAGE_SCRIPT = CHILD_PRELUDE * raw"""
using Pkg
Pkg.precompile()
const NAME = ARGS[2]

# Inspect the cache before the package loads: PkgCacheInspector warns that a
# package already in the session corrupts what it reports.
using PkgCacheInspector
cf = info_cachefile(NAME)

open(OUT, "w") do io
    row(io, "bytes", cf.filesize)
    sizes = cf.cachesizes
    for field in fieldnames(typeof(sizes))
        row(io, "segment", field, getfield(sizes, field))
    end
    row(io, "count", "external_methods", length(cf.external_methods))
    row(io, "count", "specializations", length(cf.new_specializations))
    row(io, "count", "roots", length(cf.new_method_roots))
    row(io, "count", "edges", length(cf.edges))
    by_method = Dict{Method,Int}()
    for ci in cf.new_specializations
        mi = Core.Compiler.get_ci_mi(ci)
        mi.def isa Method || continue
        by_method[mi.def] = get(by_method, mi.def, 0) + 1
    end
    for (m, n) in by_method
        file, line = place(m)
        row(io, "specialized", owner(m), file, line, first(split(string(m), " @ ")), n)
    end
end
"""

"""
    PackageImage

What a package's precompiled image holds: the file `bytes`, its `segments`
(name => bytes), `counts` (`external_methods`, `specializations`, `roots`,
`edges`), and `specialized`, the [`Findings`](@ref) for every method the image
specialized, by how many specializations it holds.
"""
struct PackageImage
  package::String
  bytes::Int
  segments::Dict{String,Int}
  counts::Dict{String,Int}
  specialized::Findings
end

function Base.show(io::IO, ::MIME"text/plain", image::PackageImage; max::Int=20)
  print(io, "package image of ", image.package, ": ", image.bytes, " bytes")
  for key in ("external_methods", "specializations", "roots", "edges")
    print(io, "\n  ", rpad(key, 18), lpad(get(image.counts, key, 0), 6))
  end
  println(io)
  return show(io, MIME"text/plain"(), image.specialized; max)
end

function Base.show(io::IO, image::PackageImage)
  return print(io, "PackageImage(", repr(image.package), ")")
end

"""
    image(target=pwd(); owned_only=false, owners=String[])

What the package's precompiled image holds, read from the cache file in a clean
process before the package loads.

The counts and sizes are facts about one build and are not good or bad on their
own: precompiling a user's common first call grows the image and speeds it up,
while specializing hundreds of unrelated upstream methods grows it for nothing.
`specialized` is what tells the two apart, listing each method the image
specialized, with its owner and how many specializations it holds. `owned_only`
keeps the methods the target owns, plus any `owners` you name; the rest are
what the image holds for other people's code.

The package's own environment must be instantiated.
"""
function image(target=pwd(); owned_only::Bool=false, owners=String[])
  root = package_root(target)
  name = package_name(root)
  lines = run_child(root, IMAGE_SCRIPT, name)
  bytes = 0
  segments, counts = Dict{String,Int}(), Dict{String,Int}()
  items = Finding[]
  for line in lines
    fields = split(line, '\t')
    kind = first(fields)
    if kind == "bytes"
      bytes = parse(Int, fields[2])
    elseif kind == "segment"
      segments[fields[2]] = parse(Int, fields[3])
    elseif kind == "count"
      counts[fields[2]] = parse(Int, fields[3])
    elseif kind == "specialized"
      _, module_name, file, ln, method, n = fields
      owned_only && !owned(module_name, name, owners) && continue
      push!(
        items,
        Finding(
          relative_file(file, root),
          parse(Int, ln),
          method,
          parse(Int, n),
          "specializations; owner $module_name",
        ),
      )
    end
  end
  return PackageImage(name, bytes, segments, counts, ranked("specialized methods", items))
end
