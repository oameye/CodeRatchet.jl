const TRIGGERS_SCRIPT = CHILD_PRELUDE * raw"""
using Pkg
Pkg.precompile()
const NAME = ARGS[2]
const WORKLOAD = ARGS[3]

using SnoopCompileCore
# The package loads before the capture: the question is what still compiles when
# the workload runs against the image that was already built.
Base.require(Main, Symbol(NAME))
tinf = @snoop_inference Base.include_string(Main, WORKLOAD)

using SnoopCompile
open(OUT, "w") do io
    for trigger in inference_triggers(tinf)
        mi = Core.Compiler.get_ci_mi(trigger.node.ci)
        m = mi.def
        m isa Method || continue
        file, line = place(m)
        caller = trigger.callerframes[1]
        row(io, owner(m), file, line, signature(mi),
            round(Int, 1e6 * inclusive(trigger.node)),
            round(Int, 1e6 * exclusive(trigger.node)),
            caller.func, caller.file, caller.line)
    end
end
"""

"""
    triggers(target=pwd(); workload, owners=String[], owned_only=false)

The compiler work that still ran when `workload` ran, against a package image
that was already built, costliest first.

Each finding is one specialization that entered inference: its method's source
location, its exact signature, and `value`, the inclusive inference time in
microseconds. That time is a measurement and varies with the machine; the set of
triggers does not, which is why the findings are the signatures and not a total.
Precompiling a signature (a `precompile` call or a `PrecompileTools` workload)
removes its trigger.

`workload` is Julia code, evaluated in a fresh process after the package loads.
The detail names the method's owner and the frame that called it. `owned_only`
keeps just the methods the target owns, plus any `owners` you name.

The package's own environment must be instantiated.
"""
function triggers(
  target=pwd(); workload::AbstractString, owners=String[], owned_only::Bool=false
)
  root = package_root(target)
  name = package_name(root)
  lines = run_child(root, TRIGGERS_SCRIPT, name, workload)
  items = Finding[]
  for line in lines
    module_name, file, ln, sig, inclusive_us, exclusive_us, caller, caller_file, caller_line = split(
      line, '\t'
    )
    owned_only && !owned(module_name, name, owners) && continue
    push!(
      items,
      Finding(
        relative_file(file, root),
        parse(Int, ln),
        sig,
        parse(Int, inclusive_us),
        "µs inclusive, $(exclusive_us) µs exclusive; owner $module_name; called from $caller at $(relative_file(caller_file, root)):$caller_line",
      ),
    )
  end
  return ranked("inference triggers", items)
end
