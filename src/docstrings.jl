"""
Macro names that declare a name public. `@public` covers `SciMLPublic.@public`
and `Compat.@public` alike, since the macro's own module is not in the syntax
tree at the call site.
"""
const PUBLIC_MACROS = ("@public", "@compat")

function add_name!(into::Set{String}, x)
  name = defname(x)
  isempty(name) || push!(into, name)
  return nothing
end

# `export a, b` and `public a, b`; `@public a, b` carries its names as a tuple or
# as bare arguments depending on how it was written, so both shapes are walked.
function declared_public!(into::Set{String}, e::Expr)
  if oneof(e.head, (:export, :public))
    foreach(a -> add_name!(into, a), e.args)
  elseif e.head === :macrocall && oneof(defname(e.args[1]), PUBLIC_MACROS)
    for a in e.args[2:end]
      a isa LineNumberNode && continue
      if a isa Expr && a.head === :tuple
        foreach(t -> add_name!(into, t), a.args)
      else
        add_name!(into, a)
      end
    end
  end
  return nothing
end

# A docstring wrapping a definition documents it. A bare `"doc" f` above a name
# with no definition documents `f` too, which is how a function with many methods
# is documented once.
function documented!(into::Set{String}, e::Expr)
  e.head === :macrocall || return nothing
  defname(e.args[1]) == "@doc" || return nothing
  target = e.args[end]
  name = definition_name(target)
  isempty(name) && (name = defname(target))
  isempty(name) || push!(into, name)
  return nothing
end

# Docstring wrappers are walked through rather than counted, so a documented
# definition is reached at the definition itself.
function defined!(into::Dict{String,Tuple{String,Int}}, rel::String, e::Expr, line::Int)
  (oneof(e.head, DEFINITION_HEADS) || is_function_assignment(e)) || return nothing
  name = definition_name(e)
  isempty(name) || haskey(into, name) || (into[name] = (rel, line))
  return nothing
end

"""
    docstrings(target=pwd(); paths=["src", "ext"])

Every public name with no docstring, at the line that defines it.

Public means declared public: an `export` line, a `public` declaration, or a
`@public` macro. A name nothing declares is internal and is not reported. A name
documented anywhere in the package counts as documented, because a function with
methods in four files is documented once. Pure syntax, about a second.
"""
function docstrings(target=pwd(); paths=["src", "ext"])
  root = package_root(target)
  public, documented = Set{String}(), Set{String}()
  defined = Dict{String,Tuple{String,Int}}()
  for rel in source_files(root, paths)
    walk(parse_file(root, rel)) do e, line
      declared_public!(public, e)
      documented!(documented, e)
      defined!(defined, rel, e, line)
      return nothing
    end
  end
  items = Finding[]
  for name in setdiff(intersect(keys(defined), public), documented)
    rel, line = defined[name]
    push!(items, Finding(rel, line, name, 1, "public, no docstring"))
  end
  return ranked("docstrings", items)
end
