"""
    Boxes()

Captured variables the compiler could not type, per file.

A `Core.Box` is what lowering emits when a closure captures a variable whose
binding is reassigned: the value goes behind an untyped indirection, every read
of it is a dynamic lookup, and inference stops at the boundary. The scan reads
lowered code, so it needs no types, no inputs and no test suite. It does need
the package loaded, which is why this is not free the way `Style` is.

Derived from `contrib/scan-closure-boxes.jl` in JuliaLang/julia (MIT), and
equivalent to `Test.detect_closure_boxes`, which ships on 1.14 and later.
"""
struct Boxes <: Metric end

metric_name(::Boxes) = "boxes"
binding(::Boxes) = ("boxes",)
row_numbers(::Boxes) = ("boxes",)

"""
    boxes_settings(rulings) -> NamedTuple

The `[boxes]` block: the package to load, and anything to load before it.
"""
function boxes_settings(rulings::Rulings)
  block = get(rulings.raw, "boxes", Dict{String,Any}())
  package = get(block, "package", nothing)
  package === nothing && error(
    "the boxes metric needs a [boxes] block in $RULINGS naming `package`, the " *
    "package whose methods should be scanned.",
  )
  return (
    package=String(package), load=String[String(p) for p in get(block, "load", String[])]
  )
end

"""
    provenance(::Boxes, root)

`julia` is recorded **and compared**, unlike every other provenance field but
the tool identity.

Lowering decides what boxes, and lowering changes between releases: 1.12 stopped
boxing a capture reassigned *before* the closure is built, which is the textbook
example and a common one. A baseline taken on one minor version is therefore not
comparable to a run on another, and comparing them silently would hand back
either a phantom improvement or a red gate nobody can act on. Failing on the
mismatch says what actually happened and asks for a refresh.
"""
function provenance(::Boxes, root::AbstractString)
  settings = boxes_settings(read_rulings(ratchet_dir(root)))
  return Dict{String,Any}(
    "metric" => "boxes",
    "attribution" => "method_definition_file",
    "package" => settings.package,
    "julia" => string(VERSION.major, ".", VERSION.minor),
    "commit" => short_commit(root),
  )
end

"""
    is_box_call(e) -> Bool

Whether `e` constructs a `Core.Box`, written as a call or as `%new`.

Both forms appear, and which one you get depends on the shape of the capture,
so matching only the call would miss a real box.
"""
function is_box_call(e)
  e isa Expr || return false
  e.head in (:call, :new) || return false
  isempty(e.args) && return false
  callee = e.args[1]
  callee === Core.Box && return true
  return callee isa GlobalRef && callee.mod === Core && callee.name === :Box
end

"""
    root_module(mod) -> Module

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
    method_boxes(m) -> Int

How many boxes one method's lowered code allocates.

A method whose source cannot be recovered counts zero rather than failing. That
is a deliberate under-count: a generated or `ccall`-only method has no lowered
body to read, and refusing to measure the package because one method is opaque
would trade a whole gate for a rounding error.
"""
function method_boxes(m::Method)
  code = try
    Base.uncompressed_ast(m).code
  catch
    return 0
  end
  n = 0
  for stmt in code
    if stmt isa Expr && stmt.head === :(=) && length(stmt.args) == 2
      is_box_call(stmt.args[2]) && (n += 1)
    elseif is_box_call(stmt)
      n += 1
    end
  end
  return n
end

function measure(::Boxes, root::AbstractString; dir::AbstractString=ratchet_dir(root))
  rulings = read_rulings(dir)
  settings = boxes_settings(rulings)
  isdefined(Base, :visit) || error(
    "the boxes metric needs `Base.visit`, which this Julia does not have " *
    "(running $(VERSION)). It is present on 1.12 and later.",
  )

  for name in settings.load
    Base.require(Main, Symbol(name))
  end
  target = Base.require(Main, Symbol(settings.package))

  # Every file in scope gets a row, zeros included, so a clean file is
  # distinguishable from one the scan never reached.
  rows = Dict{String,Row}(
    rel => Row(Dict("boxes" => 0)) for rel in scoped_files(root, rulings.scope)
  )
  Base.visit(Core.methodtable) do m
    root_module(m.module) === target || return nothing
    n = method_boxes(m)
    n == 0 && return nothing
    rel = relative_to(String(m.file), root)
    haskey(rows, rel) && (rows[rel].numbers["boxes"] += n)
    return nothing
  end
  return rows
end

"""
    boxed_methods(root; dir) -> Vector{String}

Every boxed method, named, for a person about to fix them.

The ratchet reports a count and a count is not actionable: the fix is `let x = x`,
a type annotation, an explicit `Ref`, or a function barrier, and choosing between
them needs the variable's name.
"""
function boxed_methods(root::AbstractString=pwd(); dir::AbstractString=ratchet_dir(root))
  rulings = read_rulings(dir)
  settings = boxes_settings(rulings)
  for name in settings.load
    Base.require(Main, Symbol(name))
  end
  target = Base.require(Main, Symbol(settings.package))
  found = String[]
  Base.visit(Core.methodtable) do m
    root_module(m.module) === target || return nothing
    code = try
      Base.uncompressed_ast(m)
    catch
      return nothing
    end
    for stmt in code.code
      stmt isa Expr && stmt.head === :(=) && length(stmt.args) == 2 || continue
      is_box_call(stmt.args[2]) || continue
      push!(
        found,
        "$(relative_to(String(m.file), root)):$(m.line): `$(m.name)` boxes " *
        "`$(slot_name(code, stmt.args[1]))`",
      )
    end
    return nothing
  end
  return sort!(found)
end

"""
    slot_name(code, slot) -> String

The source name of a lowered slot, which is what makes a box fixable.
"""
function slot_name(code, slot)
  slot isa Core.SlotNumber || return string(slot)
  index = Int(slot.id)
  return 1 <= index <= length(code.slotnames) ? string(code.slotnames[index]) : string(slot)
end
