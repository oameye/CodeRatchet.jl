"""
Scaffolding a repository, so adopting the gate is one command rather than three
hand-written files.

Everything written here is derivable from the repository: the package name and
UUID from its `Project.toml`, the measured scope from the directories that
exist, and the unmeasured paths from every other directory git already tracks
`.jl` files in. That last one matters more than it looks. A hand-written
`rulings.toml` almost always misses a directory, and the gate's first run is
then a list of orphaned files rather than a green tick, which is exactly the
moment someone decides this tool is not worth it.
"""

"""
    package_identity(root) -> NamedTuple

The `name` and `uuid` from the repository's own `Project.toml`.

Empty strings when there is no package there. A repository of scripts is a
legitimate thing to ratchet, and the metrics that need a loadable package are
the ones left out of the generated config.
"""
function package_identity(root::AbstractString)
  path = joinpath(root, "Project.toml")
  isfile(path) || return (name="", uuid="")
  raw = try
    TOML.parsefile(path)
  catch
    return (name="", uuid="")
  end
  return (name=String(get(raw, "name", "")), uuid=String(get(raw, "uuid", "")))
end

"""
    scope_split(root) -> (measured, unmeasured)

Which top-level directories to measure, and which to declare and skip.

`src/` and `ext/` are library code and are measured. Everything else git tracks
a `.jl` file in is declared unmeasured, so the generated config is complete on
the first run. Declaring them is not the same as ignoring them: an
`[[unmeasured_path]]` is a written decision, and a directory that appears later
still fails the gate until someone makes the same decision about it.
"""
function scope_split(root::AbstractString)
  measured = String[d * "/" for d in ("src", "ext") if isdir(joinpath(root, d))]
  isempty(measured) && (measured = ["src/"])
  others = Set{String}()
  for rel in tracked_julia_files(root)
    any(p -> startswith(rel, p), measured) && continue
    slash = findfirst(==('/'), rel)
    push!(others, slash === nothing ? rel : rel[1:slash])
  end
  return measured, sort(collect(others))
end

"""
    unmeasured_reason(path) -> String

A starting reason for skipping `path`, honest about being a guess where it is
one. A generated reason nobody edits is still better than a missing entry,
because the entry is what makes the decision visible enough to argue with.
"""
function unmeasured_reason(path::AbstractString)
  stem = rstrip(path, '/')
  stem == "test" && return "Test code. It has its own standards."
  stem == "docs" && return "Documentation build scripts, not library code."
  stem == "benchmark" && return "Benchmark harness, not library code."
  stem == "examples" && return "Example scripts, run by the docs build."
  return "Not library code. Replace this reason, or move the path into [scope]."
end

"""
    ratchet_project(identity) -> String

The `code_ratchet/Project.toml`, an environment of its own.

Separate from `test/` on purpose: the cheap gates load nothing under
measurement and must stay cheap, and only the expensive ones need the package
itself.
"""
function ratchet_project(identity)
  io = IOBuffer()
  println(io, "# The code-quality environment, separate from test/ on purpose: the cheap")
  println(io, "# gates load nothing under measurement and only the expensive ones need the")
  println(io, "# package itself.")
  println(io, "#")
  println(
    io, "# CodeRatchet is not registered, so [sources] names the repository. The rev is"
  )
  println(io, "# a commit rather than a branch: a gate's numbers depend on the tool that")
  println(io, "# measured them, so a tool free to move would move the gate underneath you.")
  println(io)
  # A repository whose package IS CodeRatchet needs one entry, not two. Emitting
  # both produced a duplicate key and a file that does not parse, which is what
  # pointing this at its own repository found.
  itself = identity.name == "CodeRatchet"
  println(io, "[deps]")
  println(io, "CodeRatchet = \"0e86a969-c127-44ad-8bee-7851ffae31d4\"")
  itself ||
    isempty(identity.uuid) ||
    println(io, identity.name, " = ", repr(identity.uuid), "  # the boxes and jet metrics")
  println(io, "JET = \"c3a54625-cd67-489e-a8e7-0a5a0ff4e31b\"")
  println(io)
  println(io, "[sources]")
  if itself
    println(io, "CodeRatchet = {path = \"..\"}")
  else
    println(
      io,
      "CodeRatchet = {url = \"https://github.com/oameye/CodeRatchet.jl\", rev = \"main\"}",
    )
    isempty(identity.name) || println(io, identity.name, " = {path = \"..\"}")
  end
  return String(take!(io))
end

"""
    ratchet_rulings(identity, measured, unmeasured) -> String

The hand-written half, generated with the parts a repository cannot guess left
commented out.

Only the three metrics that need no extra setup are switched on. `boxes` and
`jet` need a loadable package, `lsp` needs a binary, and `coverage` needs a
tracefile. Switching them on for a repository that cannot run them would make
the first `all check` fail for a reason that has nothing to do with its code.
"""
function ratchet_rulings(identity, measured, unmeasured)
  io = IOBuffer()
  println(io, "# The hand-written half of the gate. Nothing here is measured, and no verb")
  println(io, "# in CodeRatchet rewrites this file: the baselines beside it are rewritten")
  println(io, "# wholesale, and no human paragraph should share a file with that.")
  println(io)
  println(io, "[metrics]")
  println(io, "# Every gate `all` runs. Add \"coverage\", \"boxes\", \"lsp\" and \"jet\"")
  println(io, "# once their blocks below are filled in.")
  println(io, "run = [\"complexity\", \"style\", \"docs\"]")
  println(io)
  println(io, "[scope]")
  println(io, "measure = [", join(map(repr, measured), ", "), "]")
  println(io)
  println(io, "# A starting point, not a recommendation. The ratchet holds whatever a file")
  println(io, "# already measures, so these decide what counts as bad rather than what")
  println(io, "# fails: raise them and the counts of definitions above them fall.")
  println(io, "[thresholds]")
  println(io, "cyclomatic = 10")
  println(io, "cognitive = 15")
  println(io, "argcount = 6")
  println(io)
  println(io, "[style]")
  println(io, "rules = [\"union_nothing\", \"underscore_name\", \"implicit_kwarg\"]")
  for path in unmeasured
    println(io)
    println(io, "[[unmeasured_path]]")
    println(io, "path = ", repr(path))
    println(io, "reason = ", repr(unmeasured_reason(path)))
  end
  println(io)
  println(
    io, "# --- not switched on yet ----------------------------------------------------"
  )
  println(io, "#")
  println(io, "# [boxes]                    # needs a loadable package")
  isempty(identity.name) || println(io, "# package = ", repr(identity.name))
  println(io, "#")
  println(io, "# [jet]                      # needs a loadable package, costs minutes")
  isempty(identity.name) || println(io, "# package = ", repr(identity.name))
  println(io, "#")
  println(io, "# [lsp]                      # needs the `jetls` binary on PATH")
  isempty(identity.name) || println(io, "# entry = [\"src/", identity.name, ".jl\"]")
  return String(take!(io))
end

"""
    initialise(root; dir, force) -> Vector{String}

Write the two configuration files, and return the paths written.

An existing file is never overwritten without `force`, because `rulings.toml`
is the half a human wrote and losing it to a scaffolding command would be the
worst thing this package could do to someone.
"""
function initialise(
  root::AbstractString=pwd(); dir::AbstractString=ratchet_dir(root), force::Bool=false
)
  identity = package_identity(root)
  measured, unmeasured = scope_split(root)
  mkpath(dir)
  written = String[]
  for (name, body) in (
    ("Project.toml", ratchet_project(identity)),
    (RULINGS, ratchet_rulings(identity, measured, unmeasured)),
  )
    path = joinpath(dir, name)
    if isfile(path) && !force
      println(stderr, "kept existing ", path)
      continue
    end
    write(path, body)
    push!(written, path)
  end
  return written
end
