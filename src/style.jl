"""
The house-rule half of the gate: patterns a repository has decided against.

Pure syntax, so it loads nothing and costs about a second. Every rule here is a
*preference*, not a defect, which is exactly the kind of rule a ratchet suits:
the rules that most need holding are the ones a codebase already breaks, and an
absolute gate on those is unadoptable on the day you write it.

Two kinds of rule. A **named rule** walks the syntax tree and is precise. A
**pattern rule** is a regex over the file's lines, for a repository idiom no
built-in covers. Named rules first: a regex that has to know Julia syntax is a
regex that is wrong on the case you have not thought of yet.
"""

"""
    StyleRule

One thing a repository has ruled against. Named or regex, never both, so the
count for a rule has one definition and one place it comes from.
"""
abstract type StyleRule end

"""
    NamedRule(name)

A built-in syntax-tree rule. See [`STYLE_RULES`](@ref) for the set.
"""
struct NamedRule <: StyleRule
  name::String
end

"""
    PatternRule(name, pattern, reason)

A repository-specific regex, counted once per matching line.

Lines rather than matches: a regex written by hand rarely anchors, and counting
every match makes the number jump on a line the author would call one breach.
"""
struct PatternRule <: StyleRule
  name::String
  pattern::Regex
  reason::String
end

rule_name(rule::StyleRule) = rule.name

"""
    Style(rules)

House-rule counts per file, one binding number per rule.

Adding a rule to a repository that already breaks it turns the gate red on
every offending file at once, because a number absent from the baseline reads
as zero. That is the intended shape: the first `refresh --accept-rise` after
adding a rule writes the debt down explicitly, in a diff a reviewer can size.
"""
struct Style <: Metric
  rules::Vector{StyleRule}
end

"""
    Style(root; dir)

Read the rule set from `[style]` in `rulings.toml`.
"""
function Style(root::AbstractString; dir::AbstractString=ratchet_dir(root))
  return Style(style_rules(read_rulings(dir)))
end

metric_name(::Style) = "style"
binding(metric::Style) = Tuple(rule_name(r) for r in metric.rules)
row_numbers(metric::Style) = binding(metric)

function provenance(metric::Style, root::AbstractString)
  return Dict{String,Any}(
    "metric" => "style",
    "rules" => sort([rule_name(r) for r in metric.rules]),
    "commit" => short_commit(root),
  )
end

"""
    style_rules(rulings) -> Vector{StyleRule}

The configured rules, named ones first.

An empty rule set is an error rather than a gate that passes everything. A
metric that measures nothing and reports PASS is the worst outcome available:
it reads as evidence.
"""
function style_rules(rulings::Rulings)
  block = get(rulings.raw, "style", Dict{String,Any}())
  rules = StyleRule[]
  for name in get(block, "rules", String[])
    key = String(name)
    haskey(STYLE_RULES, key) || error(
      "unknown style rule $(repr(key)). Known rules: " *
      join(sort(collect(keys(STYLE_RULES))), ", "),
    )
    push!(rules, NamedRule(key))
  end
  for entry in get(rulings.raw, "style_pattern", Dict[])
    for field in ("name", "pattern", "reason")
      haskey(entry, field) ||
        error("every [[style_pattern]] needs `name`, `pattern` and `reason`; got $(entry)")
    end
    push!(
      rules,
      PatternRule(
        String(entry["name"]), Regex(String(entry["pattern"])), String(entry["reason"])
      ),
    )
  end
  isempty(rules) && error(
    "the style metric needs at least one rule. Add `rules` to the [style] block " *
    "in $RULINGS, or a [[style_pattern]].",
  )
  seen = Set{String}()
  for rule in rules
    rule_name(rule) in seen &&
      error("two style rules are both named $(repr(rule_name(rule)))")
    push!(seen, rule_name(rule))
  end
  return rules
end

# --- walking ----------------------------------------------------------------

"""
    parse_file(root, rel)

The file's syntax tree, or `Expr(:toplevel)` when it does not parse.

A parse failure is not swallowed: `parse_failures` fails the whole gate on it
separately, and returning an empty tree here keeps that one failure from also
appearing as every rule dropping to zero.
"""
function parse_file(root::AbstractString, rel::AbstractString)
  try
    return Meta.parseall(read(joinpath(root, rel), String); filename=rel)
  catch
    return Expr(:toplevel)
  end
end

"""
    walk(f, e)

Call `f` on every `Expr` in the tree, outermost first.
"""
function walk(f, e)
  e isa Expr || return nothing
  f(e)
  for a in e.args
    walk(f, a)
  end
  return nothing
end

# --- the named rules --------------------------------------------------------

"""
    is_nothing_type(e) -> Bool

Whether `e` names `Nothing`, written bare or qualified.
"""
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
    count_union_nothing(root, rel, tree) -> Int

`Union{Nothing,T}` in any position, however the two names are qualified.

The union is cheap for the compiler and expensive for the caller: every one of
them makes `nothing` a value the next function has to handle, and the handling
spreads. Sink the absence into a type that has a meaningful zero, a separate
method, or an error at the boundary.
"""
function count_union_nothing(root::AbstractString, rel::AbstractString, tree)
  n = 0
  walk(tree) do e
    e.head === :curly || return nothing
    length(e.args) >= 2 || return nothing
    names_union(e.args[1]) || return nothing
    any(is_nothing_type, e.args[2:end]) && (n += 1)
    return nothing
  end
  return n
end

const DEFINITION_HEADS = (:function, :macro, :struct, :abstract, :primitive, :const)

"""
    count_underscore_names(root, rel, tree) -> Int

Definitions named with a leading underscore, plus the file itself when its own
name carries one.

Julia's module system decides what is visible. A leading underscore states a
second, weaker convention beside it, and the two disagree the moment a name is
exported.

`:macrocall` is walked through rather than counted, so a documented or
`@kwdef`-wrapped definition is counted once at the definition it wraps.
"""
function count_underscore_names(root::AbstractString, rel::AbstractString, tree)
  n = startswith(basename(rel), "_") ? 1 : 0
  walk(tree) do e
    named = if e.head in DEFINITION_HEADS
      definition_name(e)
    elseif e.head === :(=) && e.args[1] isa Expr && e.args[1].head in (:call, :where)
      definition_name(e)
    else
      ""
    end
    startswith(named, "_") && (n += 1)
    return nothing
  end
  return n
end

"""
    count_implicit_kwargs(root, rel, tree) -> Int

Keyword arguments passed at a call site with no `;` before them: `f(a = 1)`
rather than `f(; a = 1)`.

The semicolon is what tells a reader, at the call site, that the name binds to
a keyword rather than to a position. Julia does not need it and a reader does.

Definition signatures are exempt, and the exemption is load-bearing rather than
lenient: `f(x, a = 1)` in a signature declares an *optional positional*
argument, which the parser also represents as `:kw`. Counting those would flag
a construct that has nothing to do with keywords.
"""
function count_implicit_kwargs(root::AbstractString, rel::AbstractString, tree)
  return kwargs_in(tree)
end

function kwargs_in(e)
  e isa Expr || return 0
  if e.head in (:function, :macro) && length(e.args) >= 2
    return kwargs_in_signature(e.args[1]) + sum(kwargs_in, e.args[2:end]; init=0)
  elseif e.head === :(=) &&
    length(e.args) == 2 &&
    e.args[1] isa Expr &&
    e.args[1].head in (:call, :where)
    return kwargs_in_signature(e.args[1]) + kwargs_in(e.args[2])
  end
  n = 0
  if e.head === :call
    for a in e.args[2:end]
      a isa Expr && a.head === :kw && (n += 1)
    end
  end
  return n + sum(kwargs_in, e.args; init=0)
end

"""
    kwargs_in_signature(sig) -> Int

Count inside a definition signature, where a top-level `:kw` is a positional
default rather than a keyword. Default *values* are ordinary code and are
counted normally, so `f(x = g(a = 1))` still reports the inner call.
"""
function kwargs_in_signature(sig)
  sig isa Expr || return 0
  if sig.head === :where
    return kwargs_in_signature(sig.args[1]) + sum(kwargs_in, sig.args[2:end]; init=0)
  end
  sig.head === :call || return kwargs_in(sig)
  n = 0
  for a in sig.args[2:end]
    if a isa Expr && a.head === :kw
      n += sum(kwargs_in, a.args[2:end]; init=0)
    elseif a isa Expr && a.head === :parameters
      for p in a.args
        n += if p isa Expr && p.head === :kw
          sum(kwargs_in, p.args[2:end]; init=0)
        else
          kwargs_in(p)
        end
      end
    else
      n += kwargs_in(a)
    end
  end
  return n
end

"""
The named rules, by the name a `rulings.toml` writes. Each takes the root, the
repository-relative path and the parsed tree, and returns a count.
"""
const STYLE_RULES = Dict{String,Function}(
  "union_nothing" => count_union_nothing,
  "underscore_name" => count_underscore_names,
  "implicit_kwarg" => count_implicit_kwargs,
)

# --- measuring --------------------------------------------------------------

function count_rule(rule::NamedRule, root, rel, tree, lines)
  return STYLE_RULES[rule.name](root, rel, tree)
end
function count_rule(rule::PatternRule, root, rel, tree, lines)
  return count(line -> occursin(rule.pattern, line), lines)
end

function measure(metric::Style, root::AbstractString)
  rows = Dict{String,Row}()
  for rel in scoped_files(root, read_rulings(ratchet_dir(root)).scope)
    tree = parse_file(root, rel)
    lines = try
      readlines(joinpath(root, rel))
    catch
      String[]
    end
    rows[rel] = Row(
      Dict(rule_name(r) => count_rule(r, root, rel, tree, lines) for r in metric.rules)
    )
  end
  return rows
end

"""
    style_candidates(root; dir) -> Vector{Candidate}

Files breaching a house rule, ranked by breach count.

Unlike complexity there is no threshold to divide by, so the rank is the count
itself: one file with nine breaches outranks three files with one each, which
is the order a person would work them in.
"""
function style_candidates(root::AbstractString; dir::AbstractString=ratchet_dir(root))
  metric = Style(root; dir)
  found = Candidate[]
  for (rel, row) in measure(metric, root)
    for rule in metric.rules
      n = get(row, rule_name(rule), 0)
      n > 0 && push!(found, Candidate(rel, "style", "$(rule_name(rule)) x$n", Float64(n)))
    end
  end
  return found
end
