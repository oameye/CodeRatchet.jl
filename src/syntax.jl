# --- which code a call looks at ---------------------------------------------

"""
    package_root(target) -> String

The directory to measure: a module's package directory, or a path as given.
"""
function package_root(mod::Module)
  dir = pkgdir(mod)
  dir === nothing && throw(
    ArgumentError("$mod is not a package module, so it has no directory; pass a path")
  )
  return String(dir)
end
package_root(path::AbstractString) = abspath(path)

"""
    source_files(root, paths) -> Vector{String}

Every `.jl` file under `paths` (relative to `root`), as `/`-separated paths
relative to `root`, sorted. A path that does not exist is skipped, so the
default `["src", "ext"]` fits a package with no extensions.

A file that does not parse is an error, not a zero: the syntax-level metrics
read an unparsable file as empty, and a tool that quietly stops measuring a
file is worse than one that refuses.
"""
function source_files(root::AbstractString, paths)
  files = String[]
  for path in paths
    start = joinpath(root, path)
    if isfile(start)
      push!(files, relative_to(start, root))
    elseif isdir(start)
      for (dir, _, names) in walkdir(start)
        for name in names
          endswith(name, ".jl") && push!(files, relative_to(joinpath(dir, name), root))
        end
      end
    end
  end
  sort!(unique!(files))
  unparsable = String[f for f in files if !parses(joinpath(root, f))]
  isempty(unparsable) || throw(
    ArgumentError("cannot measure files that do not parse: " * join(unparsable, ", "))
  )
  return files
end

function parses(path::AbstractString)
  try
    JuliaSyntax.parseall(JuliaSyntax.SyntaxNode, read(path, String); ignore_errors=false)
    return true
  catch
    return false
  end
end

"""
    relative_to(path, root) -> String

`path` relative to `root` with `/` separators. A path outside `root` comes back
unchanged, so a method defined elsewhere never matches a file here.
"""
function relative_to(path::AbstractString, root::AbstractString)
  p = replace(String(path), '\\' => '/')
  base = replace(abspath(root), '\\' => '/')
  base = endswith(base, "/") ? base : base * "/"
  startswith(p, base) && (p = p[(length(base) + 1):end])
  return startswith(p, "./") ? p[3:end] : p
end

function parse_file(root::AbstractString, rel::AbstractString)
  return Meta.parseall(read(joinpath(root, rel), String); filename=rel)
end

# --- walking a tree ---------------------------------------------------------

"""
    walk(f, e, line=0)

Call `f(expr, line)` on every `Expr` in the tree, outermost first. `line` is the
source line of the nearest preceding `LineNumberNode`, which is what the parser
leaves in place of positions.
"""
function walk(f, e, line::Int=0)
  e isa Expr || return nothing
  f(e, line)
  for a in e.args
    if a isa LineNumberNode
      line = a.line
    else
      walk(f, a, line)
    end
  end
  return nothing
end

oneof(x, options) = (x in options)::Bool

# --- names ------------------------------------------------------------------

const DEFINITION_HEADS = (:function, :macro, :struct, :abstract, :primitive, :const)

defname(x::Symbol) = String(x)
defname(x::QuoteNode) = defname(x.value)
# A docstring parses to `Expr(:macrocall, GlobalRef(Core, Symbol("@doc")), …)`,
# and a GlobalRef is neither a Symbol nor an Expr.
defname(x::GlobalRef) = defname(x.name)
defname(::Any) = ""
function defname(e::Expr)
  isempty(e.args) && return ""
  oneof(e.head, (:call, :where, :(<:), :curly, :macrocall)) && return defname(e.args[1])
  oneof(e.head, (:(::), :.)) && return defname(e.args[end])
  return ""
end

"""
    unwrap(e)

Drop a docstring wrapper, since a documented definition would otherwise be named
after the doc macro.
"""
function unwrap(e)
  if e isa Expr && e.head === :macrocall && defname(e.args[1]) == "@doc"
    return unwrap(e.args[end])
  end
  return e
end

function is_function_assignment(e::Expr)
  return e.head === :(=) && e.args[1] isa Expr && oneof(e.args[1].head, (:call, :where))
end

"""
    definition_name(e) -> String

The name a top-level expression defines, or `""` when it declares nothing a
reader would name.
"""
function definition_name(e0)
  e = unwrap(e0)
  e isa Expr || return ""
  if oneof(e.head, (:function, :macro))
    return defname(e.args[1])
  elseif is_function_assignment(e)
    return defname(e.args[1])
  elseif e.head === :struct
    return length(e.args) >= 2 ? defname(e.args[2]) : ""
  elseif oneof(e.head, (:abstract, :primitive))
    return isempty(e.args) ? "" : defname(e.args[1])
  elseif e.head === :const
    return e.args[1] isa Expr ? defname(e.args[1].args[1]) : defname(e.args[1])
  elseif e.head === :macrocall
    # A macro wrapping a definition names the definition, not the macro.
    inner = definition_name(e.args[end])
    return isempty(inner) ? defname(e.args[1]) : inner
  end
  return ""
end
