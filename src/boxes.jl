"""
    is_box_call(e) -> Bool

Whether `e` constructs a `Core.Box`, written as a call or as `%new`. Both forms
appear, and which one you get depends on the shape of the capture.
"""
function is_box_call(e)
  e isa Expr || return false
  oneof(e.head, (:call, :new)) || return false
  isempty(e.args) && return false
  callee = e.args[1]
  callee === Core.Box && return true
  return callee isa GlobalRef && callee.mod === Core && callee.name === :Box
end

"""
The top-level package a module belongs to, so a submodule's methods count
against the package that defines them.
"""
function root_module(mod::Module)
  while true
    parent = parentmodule(mod)
    (parent === mod || parent === Main || parent === Core) && return mod
    mod = parent
  end
end

"""
The source name of a lowered slot, which is what makes a box fixable.
"""
function slot_name(code, slot)
  slot isa Core.SlotNumber || return string(slot)
  index = Int(slot.id)
  return 1 <= index <= length(code.slotnames) ? string(code.slotnames[index]) : string(slot)
end

function method_boxes(m::Method)
  code = try
    Base.uncompressed_ast(m)
  catch
    # A generated or `ccall`-only method has no lowered body to read.
    return Tuple{String}[]
  end
  found = Tuple{String}[]
  for stmt in code.code
    if stmt isa Expr && stmt.head === :(=) && length(stmt.args) == 2
      is_box_call(stmt.args[2]) && push!(found, (slot_name(code, stmt.args[1]),))
    elseif is_box_call(stmt)
      push!(found, ("<unnamed>",))
    end
  end
  return found
end

"""
    boxes(mod::Module; root=package_root(mod))

Every captured variable the compiler could not type, with the method and the
variable's name.

A `Core.Box` is what lowering emits when a closure captures a variable whose
binding is reassigned after the closure is built: the value goes behind an
untyped indirection, every read is a dynamic lookup, and inference stops at the
boundary. The scan reads lowered code, so it needs no types, inputs or tests, but
it does need `mod` loaded, which is why it takes the module and not a path.
`root` is the directory used to shorten file names; pass it for a module that is
not a package.

The fix is `let x = x`, a type annotation, an explicit `Ref`, or a function
barrier. Lowering changes between Julia releases, so the result is only true for
the running version.

Derived from `contrib/scan-closure-boxes.jl` in JuliaLang/julia (MIT), and
equivalent to `Test.detect_closure_boxes`, which ships on 1.14 and later.
"""
function boxes(mod::Module; root::AbstractString=package_root(mod))
  isdefined(Base, :visit) ||
    error("boxes needs `Base.visit`, present on Julia 1.12 and later; running $VERSION")
  target = root_module(mod)
  items = Finding[]
  Base.visit(Core.methodtable) do m
    root_module(m.module) === target || return nothing
    for (variable,) in method_boxes(m)
      push!(
        items,
        Finding(
          relative_to(String(m.file), root),
          Int(m.line),
          string(m.name),
          1,
          "boxes `$variable`",
        ),
      )
    end
    return nothing
  end
  return ranked("boxes (Julia $(VERSION.major).$(VERSION.minor))", items)
end
