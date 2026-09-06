"""
    Docstrings()

Public names carrying no docstring, per file.

Named `Docstrings` rather than `Docs` because `Base.Docs` already answers to
that in every session, and a metric that shadows it would break `using
CodeRatchet` for anyone who reaches for the other one. The metric's own name
stays `"docs"`, so the baseline is `docs_baseline.toml` and the verb is
`coderatchet docs check`: a type name has to avoid a collision and a
command-line word does not.

Pure syntax, so it loads nothing. Binds on the **undocumented** count rather
than on a documented one or a ratio: undocumented has a reachable zero and
moves the right way on its own, where a ratio rises when a public name is
deleted and a documented count rises when a private helper is exported.

Public means declared public: an `export` line, a `public` declaration, or a
`@public` macro such as `SciMLPublic`'s. A name nothing declares is internal,
and this metric says nothing about it, because the docstring rule most
repositories actually hold is about the interface rather than the internals.
"""
struct Docstrings <: Metric end

metric_name(::Docstrings) = "docs"
binding(::Docstrings) = ("undocumented",)
row_numbers(::Docstrings) = ("undocumented", "public")

function provenance(::Docstrings, root::AbstractString)
  return Dict{String,Any}(
    "metric" => "docs",
    "public" => "export_public_and_at_public",
    "commit" => short_commit(root),
  )
end

"""
    PUBLIC_MACROS

Macro names that declare a name public. `@public` covers `SciMLPublic.@public`
and `Compat.@public` alike, since the macro's own module is not in the syntax
tree at the call site.
"""
const PUBLIC_MACROS = ("@public", "@compat")

"""
    declared_public!(into, e)

Add every name `e` declares public.

`export a, b` and `public a, b` are `Expr(:export, ...)` and
`Expr(:public, ...)`. A `@public a, b` carries its names as a tuple or as bare
arguments depending on how it was written, so both shapes are walked.
"""
function declared_public!(into::Set{String}, e::Expr)
  if e.head in (:export, :public)
    for a in e.args
      name = defname(a)
      isempty(name) || push!(into, name)
    end
  elseif e.head === :macrocall && defname(e.args[1]) in PUBLIC_MACROS
    for a in e.args[2:end]
      a isa LineNumberNode && continue
      if a isa Expr && a.head === :tuple
        for t in a.args
          name = defname(t)
          isempty(name) || push!(into, name)
        end
      else
        name = defname(a)
        isempty(name) || push!(into, name)
      end
    end
  end
  return nothing
end

"""
    documented!(into, e)

Add the name `e` documents, when `e` is a docstring wrapping a definition.

A bare docstring above a name with no definition (`"doc" f`) documents `f` too,
which is how a function with many methods is documented once.
"""
function documented!(into::Set{String}, e::Expr)
  e.head === :macrocall || return nothing
  defname(e.args[1]) == "@doc" || return nothing
  target = e.args[end]
  name = definition_name(target)
  isempty(name) && (name = defname(target))
  isempty(name) || push!(into, name)
  return nothing
end

"""
    defined!(into, e)

Add the name `e` defines. Docstring wrappers are walked through rather than
counted, so a documented definition is reached at the definition itself.
"""
function defined!(into::Set{String}, e::Expr)
  e.head in DEFINITION_HEADS ||
    (e.head === :(=) && e.args[1] isa Expr && e.args[1].head in (:call, :where)) ||
    return nothing
  name = definition_name(e)
  isempty(name) || push!(into, name)
  return nothing
end

"""
    docs_index(root, files) -> (public, documented)

Which names the package declares public, and which carry a docstring anywhere
in it.

Package-wide rather than per file, because the two facts are stated in
different places from the definition: exports live in the module file, and a
function with methods in four files is documented once. A name documented
anywhere counts as documented everywhere, which is the rule a reader would
apply.
"""
function docs_index(root::AbstractString, files)
  public, documented = Set{String}(), Set{String}()
  for rel in files
    walk(parse_file(root, rel)) do e
      declared_public!(public, e)
      documented!(documented, e)
      return nothing
    end
  end
  return public, documented
end

function measure(::Docstrings, root::AbstractString)
  files = scoped_files(root, read_rulings(ratchet_dir(root)).scope)
  public, documented = docs_index(root, files)
  rows = Dict{String,Row}()
  for rel in files
    defined = Set{String}()
    walk(e -> defined!(defined, e), parse_file(root, rel))
    here = intersect(defined, public)
    rows[rel] = Row(
      Dict("public" => length(here), "undocumented" => length(setdiff(here, documented)))
    )
  end
  return rows
end

"""
    undocumented(root; dir) -> Vector{String}

Every public name with no docstring, by the file that defines it. What to fix,
where the ratchet only says what regressed.
"""
function undocumented(root::AbstractString=pwd(); dir::AbstractString=ratchet_dir(root))
  files = scoped_files(root, read_rulings(dir).scope)
  public, documented = docs_index(root, files)
  out = String[]
  for rel in files
    defined = Set{String}()
    walk(e -> defined!(defined, e), parse_file(root, rel))
    for name in sort(collect(setdiff(intersect(defined, public), documented)))
      push!(out, "$rel: `$name` is public and has no docstring")
    end
  end
  return out
end

"""
    docs_candidates(root; dir) -> Vector{Candidate}

Files owing docstrings, ranked by how many.
"""
function docs_candidates(root::AbstractString; dir::AbstractString=ratchet_dir(root))
  found = Candidate[]
  for (rel, row) in measure(Docstrings(), root)
    n = get(row, "undocumented", 0)
    n > 0 &&
      push!(found, Candidate(rel, "docs", "$n public name(s) undocumented", Float64(n)))
  end
  return found
end
