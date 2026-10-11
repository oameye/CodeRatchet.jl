# --- measuring in a fresh Julia process --------------------------------------
#
# Invalidations, inference triggers and the package image are properties of a
# clean process: loading the analyser first would change the very events it is
# meant to explain. So each of them runs in a child Julia, captures with the
# minimal collector, and only then loads the analysis code.

"""
The shared environment that holds the snoop tooling (SnoopCompileCore,
SnoopCompile, PkgCacheInspector). It lives beside your other named environments,
is created on first use, and is never added to the package being measured.
"""
tools_environment() = joinpath(first(DEPOT_PATH), "environments", "coderatchet")

const TOOLS = ["SnoopCompileCore", "SnoopCompile", "PkgCacheInspector"]

function ensure_tools()
  dir = tools_environment()
  isfile(joinpath(dir, "Manifest.toml")) && return dir
  mkpath(dir)
  code = "using Pkg; Pkg.add($(repr(TOOLS)))"
  cmd = `$(Base.julia_cmd()) --code-coverage=none --startup-file=no --project=$dir -e $code`
  log = IOBuffer()
  # A parent running under `Pkg.test` carries a sandboxed load path with no
  # stdlibs in it, and the child would then not find Pkg.
  clean_env = addenv(cmd, "JULIA_LOAD_PATH" => nothing, "JULIA_PROJECT" => nothing)
  ok = success(pipeline(clean_env; stdout=log, stderr=log))
  ok || error("could not install $(join(TOOLS, ", ")) into $dir:\n", String(take!(log)))
  return dir
end

function package_name(root::AbstractString)
  project = joinpath(root, "Project.toml")
  isfile(project) || throw(ArgumentError("$root has no Project.toml"))
  name = get(Base.parsed_toml(project), "name", nothing)
  name isa String || throw(ArgumentError("$project names no package"))
  return name
end

"""
    run_child(root, script, args...) -> Vector{String}

Run `script` in a clean Julia process whose active project is `root`, with the
snoop tooling visible beside it, and return the lines the script wrote to the
file named by its first argument.

The child starts with no startup file, no coverage and none of the parent's
instrumentation, because a flag inherited from the parent would change what is
being measured.
"""
function run_child(root::AbstractString, script::AbstractString, args::AbstractString...)
  tools = ensure_tools()
  out = joinpath(mktempdir(), "out.tsv")
  file = joinpath(mktempdir(), "child.jl")
  write(file, script)
  load_path = join(["@", tools, "@stdlib"], Sys.iswindows() ? ";" : ":")
  cmd = `$(Base.julia_cmd()) --code-coverage=none --startup-file=no --history-file=no --project=$root $file $out $args`
  env = addenv(cmd, "JULIA_LOAD_PATH" => load_path, "JULIA_PROJECT" => nothing)
  log = IOBuffer()
  success(pipeline(env; stdout=log, stderr=log)) ||
    error("the measuring process failed:\n", String(take!(log)))
  return isfile(out) ? readlines(out) : String[]
end

# Shared by every script: one cell of output per field, no tabs or newlines in it.
const CHILD_PRELUDE = raw"""
const OUT = ARGS[1]
clean(x) = replace(string(x), r"[\t\r\n]+" => " ")
row(io, fields...) = println(io, join(map(clean, fields), '\t'))

# One spelling of a specialization, shared by every finding so they line up.
function signature(mi)
    mi isa Core.MethodInstance || return clean(mi)
    return clean(mi.specTypes)
end
function owner(m::Method)
    return string(nameof(Base.moduleroot(m.module)))
end
function place(m::Method)
    return (clean(m.file), Int(m.line))
end
"""

relative_file(file::AbstractString, root::AbstractString) = relative_to(file, root)

function owned(owner::AbstractString, name::AbstractString, owners)
  return owner == name || owner in owners
end
