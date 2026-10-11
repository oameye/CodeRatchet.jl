const INVALIDATIONS_SCRIPT =
  CHILD_PRELUDE * raw"""
using Pkg
Pkg.precompile()
const NAME = ARGS[2]
const WORKLOAD = ARGS[3]

using SnoopCompileCore
invs = @snoop_invalidations begin
    Base.require(Main, Symbol(NAME))
    isempty(WORKLOAD) || Base.include_string(Main, WORKLOAD)
end

# The analyser loads only after the capture, so it cannot add events to it.
using SnoopCompile
depth(node) = 1 + maximum(depth, node.children; init=0)

# SnoopCompile 3.2.9 cannot read the part of the log a redefined binding writes:
# its backedge parser accepts only the two method-table tags and throws on
# `jl_maybe_log_binding_invalidation`. In `logmeths` an event is a run of
# `MethodInstance, Int32|String` pairs followed by its cause, `Method, String` or,
# here, `BindingPartition, String`. Take the binding events out before the
# analyser sees them and report them ourselves, so the method events in the same
# capture still parse.
function split_bindings(logmeths)
    kept, pending = Any[], Any[]
    bindings = 0
    i = 1
    while i <= length(logmeths)
        item = logmeths[i]
        if item isa Core.MethodInstance
            push!(pending, item, logmeths[i + 1])
            i += 2
        elseif item isa Method
            push!(pending, item, logmeths[i + 1])
            append!(kept, pending)
            empty!(pending)
            i += 2
        elseif item isa Core.BindingPartition
            bindings += count(x -> x isa Core.MethodInstance, pending)
            empty!(pending)
            i += 2
        else
            push!(pending, item)
            i += 1
        end
    end
    append!(kept, pending)
    return kept, bindings
end

logmeths, binding_invalidated = split_bindings(invs.logmeths)
trees = try
    invalidation_trees(SnoopCompileCore.InvalidationLists(invs.logedges, logmeths))
catch err
    error("SnoopCompile cannot read this invalidation log: ", sprint(showerror, err))
end

open(OUT, "w") do io
    binding_invalidated > 0 && row(io, "?", "", 0, "redefined binding (the log does not name it)",
        "rebinding", 0, binding_invalidated, 0)
    for tree in trees
        m = tree.method
        roots = Any[last(b) for b in tree.mt_backedges]
        append!(roots, tree.backedges)
        total = sum(r -> 1 + SnoopCompile.countchildren(r), roots; init=0)
        # A redefined global or constant invalidates code too; it has a binding,
        # not a method, so there is no source line to point at.
        who, file, line, what = if m isa Method
            (owner(m), place(m)..., first(split(string(m), " @ ")))
        else
            ref = m.globalref
            (string(nameof(Base.moduleroot(ref.mod))), "", 0, "binding $(ref.mod).$(ref.name)")
        end
        row(io, who, file, line, what, tree.reason, length(roots), total,
            maximum(depth, roots; init=0))
    end
end
"""

"""
    invalidations(target=pwd(); workload=nothing, owners=String[], all=false)

The methods that, once defined, made already-compiled code stale, worst first.

`value` is the number of compiled MethodInstances the method invalidated, and
the detail says how many roots that came from and how deep the cascade ran. A
method is only ever blamed for what it invalidated, never for what a dependency
did, so by default only methods the target package owns are listed: its own
module tree plus any `owners` you name (an extension or a companion package).
`all=true` lists every method defined during the capture, with its owner.

The capture runs in a fresh Julia process holding only SnoopCompileCore, and it
covers loading the package. `workload` is Julia code evaluated in the same
capture afterwards, for invalidations a scenario causes (loading an optional
integration, say). The package's own environment must be instantiated.

Invalidation logging changes between Julia releases, so the result is true for
the running version only.
"""
function invalidations(
  target=pwd();
  workload::Union{Nothing,AbstractString}=nothing,
  owners=String[],
  all::Bool=false,
)
  root = package_root(target)
  name = package_name(root)
  lines = run_child(root, INVALIDATIONS_SCRIPT, name, something(workload, ""))
  items = Finding[]
  for line in lines
    module_name, file, ln, method, reason, roots, total, depth = split(line, '\t')
    all || owned(module_name, name, owners) || continue
    push!(
      items,
      Finding(
        relative_file(file, root),
        parse(Int, ln),
        method,
        parse(Int, total),
        "$reason; $roots root(s), depth $depth, owner $module_name",
      ),
    )
  end
  return ranked("invalidations (Julia $(VERSION.major).$(VERSION.minor))", items)
end
