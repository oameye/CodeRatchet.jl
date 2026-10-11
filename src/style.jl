"""
The named house rules, each a function from `(rel, tree)` to the source lines
that breach it. Syntax-tree rules only: a regex that has to know Julia syntax is
wrong on the case nobody thought of, and a wrong finding has no place here.
"""
const STYLE_RULES = Dict{Symbol,Function}()

# --- union_nothing ----------------------------------------------------------

is_nothing_type(e::Symbol) = e === :Nothing
function is_nothing_type(e::Expr)
  return e.head === :. && length(e.args) == 2 && is_nothing_type(e.args[2])
end
is_nothing_type(e::QuoteNode) = is_nothing_type(e.value)
is_nothing_type(::Any) = false

names_union(e::Symbol) = e === :Union
names_union(e::Expr) = e.head === :. && length(e.args) == 2 && names_union(e.args[2])
names_union(e::QuoteNode) = names_union(e.value)
names_union(::Any) = false

"""
`Union{Nothing,T}` in any position, however the two names are qualified.

The union is cheap for the compiler and expensive for the caller: every one of
them makes `nothing` a value the next function has to handle.
"""
function union_nothing_lines(::AbstractString, tree)
  lines = Int[]
  walk(tree) do e, line
    e.head === :curly || return nothing
    length(e.args) >= 2 || return nothing
    names_union(e.args[1]) || return nothing
    any(is_nothing_type, e.args[2:end])::Bool && push!(lines, line)
    return nothing
  end
  return lines
end
STYLE_RULES[:union_nothing] = union_nothing_lines

# --- underscore_name --------------------------------------------------------

"""
Definitions named with a leading underscore, plus the file itself when its own
name carries one. Julia's module system decides visibility; a leading underscore
states a second, weaker convention that disagrees with it the moment a name is
exported.
"""
function underscore_name_lines(rel::AbstractString, tree)
  lines = startswith(basename(rel), "_") ? [1] : Int[]
  walk(tree) do e, line
    named = if oneof(e.head, DEFINITION_HEADS) || is_function_assignment(e)
      definition_name(e)
    else
      ""
    end
    startswith(named, "_") && push!(lines, line)
    return nothing
  end
  return lines
end
STYLE_RULES[:underscore_name] = underscore_name_lines

# --- implicit_kwarg ---------------------------------------------------------

function kw_children!(out::Vector{Int}, args, line::Int)
  for a in args
    if a isa LineNumberNode
      line = a.line
    else
      kw_lines!(out, a, line)
    end
  end
  return nothing
end

function kw_lines!(out::Vector{Int}, e, line::Int)
  e isa Expr || return nothing
  if oneof(e.head, (:function, :macro)) && length(e.args) >= 2
    sig_lines!(out, e.args[1], line)
    kw_children!(out, e.args[2:end], line)
    return nothing
  elseif is_function_assignment(e) && length(e.args) == 2
    sig_lines!(out, e.args[1], line)
    kw_lines!(out, e.args[2], line)
    return nothing
  end
  if e.head === :call
    for a in e.args[2:end]
      a isa Expr && a.head === :kw && push!(out, line)
    end
  end
  kw_children!(out, e.args, line)
  return nothing
end

# Inside a definition signature a top-level `:kw` is an optional positional
# argument, not a keyword. Default values are ordinary code and still count.
function sig_lines!(out::Vector{Int}, sig, line::Int)
  sig isa Expr || return nothing
  if sig.head === :where
    sig_lines!(out, sig.args[1], line)
    kw_children!(out, sig.args[2:end], line)
    return nothing
  end
  if sig.head !== :call
    kw_lines!(out, sig, line)
    return nothing
  end
  for a in sig.args[2:end]
    if a isa Expr && a.head === :kw
      kw_children!(out, a.args[2:end], line)
    elseif a isa Expr && a.head === :parameters
      for p in a.args
        if p isa Expr && p.head === :kw
          kw_children!(out, p.args[2:end], line)
        else
          kw_lines!(out, p, line)
        end
      end
    else
      kw_lines!(out, a, line)
    end
  end
  return nothing
end

"""
Keyword arguments passed at a call site with no `;`: `f(a = 1)` rather than
`f(; a = 1)`. The semicolon tells a reader the name binds to a keyword rather
than to a position.
"""
function implicit_kwarg_lines(::AbstractString, tree)
  out = Int[]
  kw_lines!(out, tree, 0)
  return out
end
STYLE_RULES[:implicit_kwarg] = implicit_kwarg_lines

"""
    style(target=pwd(); rules=collect(keys(STYLE_RULES)), paths=["src", "ext"])

Every breach of a house rule, one finding per line, with the source line as the
detail.

The rules are `:union_nothing` (`Union{Nothing,T}`), `:underscore_name` (a
definition or file named with a leading underscore) and `:implicit_kwarg`
(`f(a = 1)` instead of `f(; a = 1)`). Pure syntax, about a second.
"""
function style(target=pwd(); rules=sort(collect(keys(STYLE_RULES))), paths=["src", "ext"])
  for rule in rules
    haskey(STYLE_RULES, rule) || throw(
      ArgumentError(
        "unknown style rule $(repr(rule)); known: " *
        join(repr.(sort(collect(keys(STYLE_RULES)))), ", "),
      ),
    )
  end
  root = package_root(target)
  items = Finding[]
  for rel in source_files(root, paths)
    tree = parse_file(root, rel)
    text = readlines(joinpath(root, rel))
    for rule in rules, line in STYLE_RULES[rule](rel, tree)
      shown = 1 <= line <= length(text) ? strip(text[line]) : ""
      push!(items, Finding(rel, line, String(rule), 1, String(shown)))
    end
  end
  return ranked("style", items)
end
