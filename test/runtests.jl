using Test
using CodeRatchet
using CodeRatchet:
  Candidate,
  Complexity,
  Coverage,
  Issue,
  Row,
  Violation,
  binding,
  check,
  complexity_candidates,
  definition_name,
  definition_ranges,
  entry_failures,
  exemptions,
  jet_candidates,
  measure,
  metric_name,
  misses_by_definition,
  names_path,
  ok,
  parse_failures,
  parse_issues,
  parse_lcov,
  pair_renames,
  ratchet,
  ratchet_dir,
  read_baseline,
  read_rulings,
  refresh,
  render_baseline,
  rise_table,
  routes,
  row_numbers,
  ruling_failures,
  set_differences,
  terminal,
  tracked_julia_files,
  triage,
  unscoped_files,
  write_artifact

# A metric with no measurement behind it, so the ratchet can be tested on its
# own. Two numbers, one binding, which is the shape every real metric has.
struct Fake <: CodeRatchet.Metric end
CodeRatchet.metric_name(::Fake) = "fake"
CodeRatchet.binding(::Fake) = ("bind",)
CodeRatchet.row_numbers(::Fake) = ("bind", "context")

fake(bind, context) = Row(Dict("bind" => bind, "context" => context))

"""
    gitrepo(files; rulings) -> String

A temporary git repository holding `files`, all committed.

The fixtures are real repositories because the gate takes its file list from
`git ls-files`, deliberately: a directory walk ignores `.gitignore` and picks
up untracked scratch files.
"""
function gitrepo(files::Dict{String,String}; rulings::AbstractString="")
  root = mktempdir()
  for (rel, body) in files
    path = joinpath(root, rel)
    mkpath(dirname(path))
    write(path, body)
  end
  if !isempty(rulings)
    mkpath(joinpath(root, "code_ratchet"))
    write(joinpath(root, "code_ratchet/rulings.toml"), rulings)
  end
  run(pipeline(Cmd(`git init -q -b main`; dir=root); stdout=devnull, stderr=devnull))
  run(pipeline(Cmd(`git add -A`; dir=root); stdout=devnull, stderr=devnull))
  run(
    pipeline(
      Cmd(`git -c user.name=t -c user.email=t@t commit -q -m fixture`; dir=root);
      stdout=devnull,
      stderr=devnull,
    ),
  )
  return root
end

function track!(root, rel, body)
  path = joinpath(root, rel)
  mkpath(dirname(path))
  write(path, body)
  run(pipeline(Cmd(`git add -A`; dir=root); stdout=devnull, stderr=devnull))
  return path
end

const SRC_ONLY = """
[scope]
measure = ["src/"]

[thresholds]
cyclomatic = 3
cognitive = 15
argcount = 10

[[unmeasured_path]]
path = "test/"
reason = "Test code."
"""

@testset "CodeRatchet" begin
  @testset "the ratchet" begin
    base = Dict("a.jl" => fake(5, 50))

    @testset "steady is quiet" begin
      v, _, _, _ = ratchet(Fake(), Dict("a.jl" => fake(5, 50)), base)
      @test isempty(v)
    end

    @testset "a fall is quiet" begin
      v, _, _, _ = ratchet(Fake(), Dict("a.jl" => fake(4, 50)), base)
      @test isempty(v)
    end

    @testset "a rise is a violation, with both values" begin
      v, _, _, _ = ratchet(Fake(), Dict("a.jl" => fake(6, 50)), base)
      @test length(v) == 1
      @test v[1].path == "a.jl" && v[1].key == "bind"
      @test v[1].from == 5 && v[1].to == 6
    end

    @testset "a non-binding number may rise freely" begin
      v, _, _, _ = ratchet(Fake(), Dict("a.jl" => fake(5, 999)), base)
      @test isempty(v)
    end
  end

  @testset "set equality" begin
    @testset "a file with no row is reported, not silently passed" begin
      base = Dict("a.jl" => fake(5, 50))
      v, new, dead, _ = ratchet(
        Fake(), Dict("a.jl" => fake(5, 50), "b.jl" => fake(9, 9)), base
      )
      @test isempty(v)          # no rise: it has no baseline to rise above
      @test new == ["b.jl"]     # but the missing row is a failure of its own
      @test isempty(dead)
    end

    @testset "a row naming nothing is reported" begin
      base = Dict("a.jl" => fake(5, 50), "gone.jl" => fake(1, 1))
      _, new, dead, _ = ratchet(Fake(), Dict("a.jl" => fake(5, 50)), base)
      @test isempty(new)
      @test dead == ["gone.jl"]
    end

    @testset "set_differences reports both directions" begin
      missing_rows, dead_rows = set_differences(["a", "b"], ["b", "c"])
      @test missing_rows == ["a"]
      @test dead_rows == ["c"]
    end
  end

  @testset "rename pairing" begin
    @testset "an unambiguous rename carries its history" begin
      base = Dict("old.jl" => fake(7, 70))
      v, new, dead, renames = ratchet(Fake(), Dict("new.jl" => fake(7, 70)), base)
      @test renames == Dict("new.jl" => "old.jl")
      @test isempty(v) && isempty(new) && isempty(dead)
    end

    @testset "pairing uses every number, not just the binding one" begin
      base = Dict("old.jl" => fake(7, 70))
      _, new, dead, renames = ratchet(Fake(), Dict("new.jl" => fake(7, 71)), base)
      @test isempty(renames)
      @test new == ["new.jl"] && dead == ["old.jl"]
    end

    @testset "equal numbers pair by arithmetic, so an ambiguous set still pairs" begin
      # When the numbers are equal it does not matter which dead row takes
      # which new path: the multiset of recorded numbers cannot rise.
      base = Dict("old1.jl" => fake(7, 70), "old2.jl" => fake(7, 70))
      cur = Dict("new1.jl" => fake(7, 70), "new2.jl" => fake(7, 70))
      v, new, dead, renames = ratchet(Fake(), cur, base)
      @test length(renames) == 2
      @test isempty(v) && isempty(new) && isempty(dead)
    end
  end

  @testset "tracked files come from git" begin
    root = gitrepo(Dict("src/a.jl" => "f() = 1\n", "test/t.jl" => "using Test\n"))
    @test tracked_julia_files(root) == ["src/a.jl", "test/t.jl"]

    @testset "an untracked scratch file is not measured" begin
      write(joinpath(root, "src", "NOTRACK_scratch.jl"), "junk(\n")
      @test !("src/NOTRACK_scratch.jl" in tracked_julia_files(root))
    end

    @testset "a non-repository is an error, not a silent walk" begin
      @test_throws ErrorException tracked_julia_files(mktempdir())
    end
  end

  @testset "lcov parsing" begin
    root = mktempdir()
    write(
      joinpath(root, "lcov.info"),
      """
      SF:$(joinpath(root, "src/a.jl"))
      DA:1,3
      DA:2,0
      DA:3,0
      end_of_record
      SF:$(joinpath(root, "src/b.jl"))
      DA:1,1
      end_of_record
      """,
    )
    got = parse_lcov(joinpath(root, "lcov.info"), root)
    @test sort(collect(keys(got))) == ["src/a.jl", "src/b.jl"]
    @test count(iszero, values(got["src/a.jl"])) == 2
    @test length(got["src/a.jl"]) == 3

    @testset "records for one file accumulate across workers" begin
      write(
        joinpath(root, "split.info"),
        """
        SF:src/a.jl
        DA:1,0
        DA:2,0
        end_of_record
        SF:src/a.jl
        DA:1,4
        DA:2,0
        end_of_record
        """,
      )
      table = parse_lcov(joinpath(root, "split.info"), root)["src/a.jl"]
      @test count(iszero, values(table)) == 1   # line 1 covered by the second
    end

    @testset "a missing tracefile is an error, not a silent zero" begin
      @test_throws ErrorException parse_lcov(joinpath(root, "nope.info"), root)
    end
  end

  @testset "attributing a miss to a definition" begin
    root = gitrepo(Dict("src/a.jl" => """
                        const TABLE = [1, 2]

                        \"\"\"
                            documented(x)

                        A docstring wraps the definition in a `Core.@doc` call.
                        \"\"\"
                        function documented(x)
                          if x > 0
                            return 1
                          end
                          return 2
                        end

                        short(y) = y + 1

                        struct Holder
                          a::Int
                        end
                        """))

    ranges = definition_ranges(root, "src/a.jl")
    named = Dict(n => (a, b) for (n, a, b) in ranges)

    @testset "a documented definition is named, not attributed to the doc macro" begin
      @test haskey(named, "documented")
      @test !haskey(named, "@doc")
    end

    @testset "short form and struct are named" begin
      @test haskey(named, "short")
      @test haskey(named, "Holder")
    end

    @testset "a const has no interior line info, so it lands in <toplevel>" begin
      # `const K = 1` carries no LineNumberNode of its own: the parser leaves
      # one beside it at top level, not inside it. So a const cannot be its own
      # exemption target, and <toplevel> is the target that covers it.
      @test definition_name(Meta.parseall("const K = 1").args[2]) == "K"
      @test !haskey(named, "TABLE")
    end

    @testset "a miss lands on the definition holding it" begin
      first_line, last_line = named["documented"]
      got = misses_by_definition(root, "src/a.jl", Dict(first_line + 2 => 0, 1 => 0))
      @test got["documented"] == 1
      @test got[CodeRatchet.TOPLEVEL] == 1   # line 1 is the const
    end

    @testset "a miss inside no named definition lands on <toplevel>" begin
      got = misses_by_definition(root, "src/a.jl", Dict(10_000 => 0))
      @test got[CodeRatchet.TOPLEVEL] == 1
    end

    @testset "a covered line is not a miss" begin
      @test isempty(misses_by_definition(root, "src/a.jl", Dict(1 => 7)))
    end
  end

  @testset "definition_name" begin
    # args[1] is the LineNumberNode the parser puts before the definition.
    name(code) = definition_name(first(a for a in Meta.parseall(code).args if a isa Expr))
    @test name("f(x) = x") == "f"
    @test name("function g(x)\n x\nend") == "g"
    @test name("f(x::T) where {T} = x") == "f"
    @test name("struct S\n a::Int\nend") == "S"
    @test name("abstract type A end") == "A"
    @test name("const K = 1") == "K"
    @test name("macro m(x)\n x\nend") == "m"
    @test name("x = 1") == ""             # a plain assignment names nothing
  end

  @testset "complexity on a real repository" begin
    root = gitrepo(
      Dict(
        "src/simple.jl" => "plain(x) = x + 1\n",
        "src/branchy.jl" => """
        function branchy(x)
          if x > 10
            return 1
          elseif x > 5
            return 2
          elseif x > 0
            return 3
          else
            return 4
          end
        end
        """,
        "test/runtests.jl" => "using Test\n",
      );
      rulings=SRC_ONLY,
    )

    @testset "measure produces one row per scoped file" begin
      rows = measure(Complexity(), root)
      @test sort(collect(keys(rows))) == ["src/branchy.jl", "src/simple.jl"]
      @test rows["src/simple.jl"]["cyc"] == 1
      @test rows["src/branchy.jl"]["cyc"] >= 4
    end

    @testset "the first check is the bootstrap case, not a wall of failures" begin
      report = check(Complexity(), root)
      @test report.bootstrap
      @test ok(report)
      @test isempty(report.missing_rows)
    end

    @testset "refresh then check is clean" begin
      refresh(Complexity(), root)
      report = check(Complexity(), root)
      @test ok(report)
      @test !report.bootstrap
    end

    @testset "the maximum binds and the sum does not" begin
      open(joinpath(root, "src/branchy.jl"), "a") do io
        println(io, "helper(y) = y")
      end
      report = check(Complexity(), root)
      @test ok(report)
      rows = measure(Complexity(), root)
      base, _ = read_baseline(Complexity(), ratchet_dir(root))
      @test rows["src/branchy.jl"]["cyc_sum"] > base["src/branchy.jl"]["cyc_sum"]
      @test rows["src/branchy.jl"]["cyc"] == base["src/branchy.jl"]["cyc"]
    end

    @testset "a rise in the maximum fails" begin
      write(
        joinpath(root, "src/simple.jl"),
        """
        function nowbranchy(x)
          if x > 1
            return 1
          elseif x > 0
            return 2
          end
          return 3
        end
        """,
      )
      report = check(Complexity(), root)
      @test !ok(report)
      @test any(v -> v.path == "src/simple.jl" && v.key == "cyc", report.violations)
    end

    @testset "refresh refuses a rise without the flag" begin
      @test_throws ErrorException refresh(Complexity(), root)
      report = refresh(Complexity(), root; accept_rise=true)
      @test !isempty(report.violations)
      @test ok(check(Complexity(), root))
    end

    @testset "a NEW file with no row fails, rather than passing at any number" begin
      track!(root, "src/added.jl", "fresh(z) = z\n")
      report = check(Complexity(), root)
      @test !ok(report)
      @test "src/added.jl" in report.missing_rows
      refresh(Complexity(), root)
      @test ok(check(Complexity(), root))
    end

    @testset "an unparsable file fails the gate" begin
      track!(root, "src/broken.jl", "function h(z\nend\n")
      report = check(Complexity(), root)
      @test "src/broken.jl" in report.unparsable
      @test !ok(report)
      rm(joinpath(root, "src/broken.jl"))
      run(pipeline(Cmd(`git add -A`; dir=root); stdout=devnull, stderr=devnull))
    end

    @testset "a file measured by nothing fails the gate" begin
      track!(root, "bench/run.jl", "x = 1\n")
      report = check(Complexity(), root)
      @test "bench/run.jl" in report.unscoped
      @test !ok(report)
      rm(joinpath(root, "bench"); recursive=true)
      run(pipeline(Cmd(`git add -A`; dir=root); stdout=devnull, stderr=devnull))
    end

    @testset "provenance is recorded with a commit that never binds" begin
      text = render_baseline(Complexity(), measure(Complexity(), root), root)
      @test occursin("commit = ", text)
      @test occursin("aggregation = \"max_over_definitions\"", text)
    end
  end

  @testset "coverage" begin
    body = """
    function covered(x)
      return x + 1
    end

    function leaky(y)
      if y > 0
        return 1
      end
      return 2
    end
    """
    rulings = """
    [scope]
    measure = ["src/"]
    """
    root = gitrepo(Dict("src/a.jl" => body); rulings=rulings)
    ranges = Dict(n => (a, b) for (n, a, b) in definition_ranges(root, "src/a.jl"))
    leaky_first, leaky_last = ranges["leaky"]

    lcov(pairs) = write(
      joinpath(root, "lcov.info"),
      "SF:src/a.jl\n" * join(("DA:$l,$h" for (l, h) in pairs), "\n") * "\nend_of_record\n",
    )

    @testset "an exemption does not lower the binding number" begin
      lcov([(1, 1), (2, 1), (leaky_first + 2, 0), (leaky_last, 0)])
      rows = measure(Coverage(), root)
      @test rows["src/a.jl"]["misses"] == 2      # raw, not netted
      @test row_numbers(Coverage()) == ("lines", "misses")
    end

    @testset "an exemption above the truth is stale" begin
      write(joinpath(root, "code_ratchet/rulings.toml"), rulings * """

                                                         [[exemption]]
                                                         path = "src/a.jl"
                                                         definition = "leaky"
                                                         misses = 5
                                                         reason = "fixture"
                                                         """)
      bad = ruling_failures(Coverage(), root)
      @test length(bad) == 1
      @test occursin("claims 5", bad[1]) && occursin("2 remain", bad[1])
      @test occursin("Lower or remove", bad[1])
    end

    @testset "an exemption below the truth is the leak a file total cannot see" begin
      write(joinpath(root, "code_ratchet/rulings.toml"), rulings * """

                                                         [[exemption]]
                                                         path = "src/a.jl"
                                                         definition = "leaky"
                                                         misses = 1
                                                         reason = "fixture"
                                                         """)
      bad = ruling_failures(Coverage(), root)
      @test length(bad) == 1
      @test occursin("claims 1", bad[1]) && occursin("2 remain", bad[1])
      @test occursin("Cover the new one", bad[1])
    end

    @testset "an exact exemption is clean" begin
      write(joinpath(root, "code_ratchet/rulings.toml"), rulings * """

                                                         [[exemption]]
                                                         path = "src/a.jl"
                                                         definition = "leaky"
                                                         misses = 2
                                                         reason = "fixture"
                                                         """)
      @test isempty(ruling_failures(Coverage(), root))
      @test ok(check(Coverage(), root))
    end

    @testset "an exemption missing a field is refused" begin
      write(joinpath(root, "code_ratchet/rulings.toml"), rulings * """

                                                         [[exemption]]
                                                         path = "src/a.jl"
                                                         misses = 2
                                                         reason = "no definition named"
                                                         """)
      @test_throws ErrorException exemptions(read_rulings(ratchet_dir(root)))
      write(joinpath(root, "code_ratchet/rulings.toml"), rulings)
    end

    @testset "a new file enters fully covered or exempted" begin
      lcov([(1, 1), (2, 1), (leaky_first + 2, 0), (leaky_last, 0)])
      bad = entry_failures(Coverage(), root, ["src/a.jl"], measure(Coverage(), root))
      @test length(bad) == 1
      @test occursin("enters with 2 uncovered", bad[1])

      lcov([(1, 1), (2, 1)])
      @test isempty(
        entry_failures(Coverage(), root, ["src/a.jl"], measure(Coverage(), root))
      )
    end

    @testset "misses bind, percentage does not" begin
      lcov([(1, 1), (2, 1), (leaky_first + 2, 0), (leaky_last, 0)])
      refresh(Coverage(), root)
      # 6 of 9 covered is 67%, up from 50%, but misses go 2 -> 3.
      lcov([
        (1, 1),
        (2, 1),
        (leaky_first + 2, 0),
        (leaky_last, 0),
        (leaky_first, 1),
        (leaky_first + 1, 1),
        (2, 1),
        (leaky_last - 1, 0),   # the third miss, on a line used nowhere above
      ])
      report = check(Coverage(), root)
      @test !ok(report)
      @test report.violations[1].from == 2 && report.violations[1].to == 3
    end

    @testset "terminal lists what is still short of zero" begin
      @test any(line -> occursin("src/a.jl", line), terminal(root))
    end
  end

  @testset "triage" begin
    @testset "names_path matches whole tokens only" begin
      @test names_path("code-ratchet: reduce complexity in src/a.jl", "src/a.jl")
      @test names_path("fix `src/a.jl` please", "src/a.jl")
      @test !names_path("reduce complexity in src/a.jl.orig", "src/a.jl")
      @test !names_path("reduce complexity in other/src/a.jlx", "src/a.jl")
    end

    @testset "parse_issues skips what it cannot read" begin
      got = parse_issues("12\tOPEN\tone\nrubbish\n13\tclosed\ttwo\n")
      @test length(got) == 2
      @test got[1] == Issue(12, "OPEN", "one")
      @test got[2].state == "CLOSED"
    end

    root = gitrepo(
      Dict("src/hot.jl" => """
           function hot(a, b, c)
             if a > 0
               if b > 0
                 return c > 0 ? 1 : 2
               elseif b < -1
                 return 3
               end
             elseif a < -1
               for i in 1:10
                 i % 2 == 0 && continue
               end
               return 4
             end
             return 5
           end
           """, "src/mild.jl" => """
                function mild(x)
                  if x > 0
                    return 1
                  end
                  return 2
                end
                """); rulings=SRC_ONLY * """

                      [scheduled_job]
                      open_queue = 2
                      """
    )

    @testset "candidates rank by value over threshold, worst first" begin
      found = sort(complexity_candidates(root); by=c -> -c.rank)
      @test !isempty(found)
      @test found[1].path == "src/hot.jl"
      @test found[1].rank >= 1
    end

    @testset "one issue per file, not per definition" begin
      plan = triage(root)
      @test length(plan.file) <= 2
      paths = [t for (t, _) in plan.file]
      @test length(unique(paths)) == length(paths)
    end

    @testset "an open issue naming the file suppresses it" begin
      plan = triage(root; issues="7\tOPEN\tcode-ratchet: reduce complexity in src/hot.jl\n")
      @test !any(t -> occursin("src/hot.jl", t), [t for (t, _) in plan.file])
      @test any(s -> occursin("src/hot.jl", s) && occursin("#7", s), plan.suppressed)
    end

    @testset "the cap is on the open queue, so a full queue files nothing" begin
      full = "1\tOPEN\tunrelated one\n2\tOPEN\tunrelated two\n"
      plan = triage(root; issues=full)
      @test isempty(plan.file)
      @test plan.open_count == 2 && plan.capacity == 2
      @test any(s -> occursin("open queue is full", s), plan.suppressed)
    end

    @testset "a closed issue suppresses unless a refile is asked for" begin
      closed = "9\tCLOSED\tcode-ratchet: reduce complexity in src/hot.jl\n"
      @test !any(
        t -> occursin("src/hot.jl", t), [t for (t, _) in triage(root; issues=closed).file]
      )
      refiled = triage(root; issues=closed, refile_closed=true)
      @test any(t -> occursin("src/hot.jl", t), [t for (t, _) in refiled.file])
    end

    @testset "the body says closing without a change is legitimate" begin
      plan = triage(root)
      @test any(
        b -> occursin("Closing without a change is a legitimate outcome", b),
        [b for (_, b) in plan.file],
      )
    end

    @testset "jet candidates are read from the baseline, not by re-running" begin
      mkpath(joinpath(root, "code_ratchet"))
      write(
        joinpath(root, "code_ratchet/jet_baseline.toml"),
        """
        [provenance]
        metric = "jet"

        [files."src/hot.jl"]
        raw = 3
        reviewed = 2

        [files."src/mild.jl"]
        raw = 1
        reviewed = 0
        """,
      )
      found = jet_candidates(root)
      @test length(found) == 1
      @test found[1].path == "src/hot.jl"
      @test occursin("2 reviewed", found[1].detail)
    end
  end

  @testset "reporting" begin
    @testset "the remedy names a refresh last, not first" begin
      text = routes(; dismissal="")
      @test occursin("A refresh is not the fix", text)
      @test findfirst("Lower the number", text)[1] < findfirst("Record the rise", text)[1]
    end

    @testset "the dismissal route appears only where the metric has one" begin
      @test occursin("[[dismissal]]", routes(; dismissal="dismissal"))
      @test occursin("[[lsp_dismissal]]", routes(; dismissal="lsp_dismissal"))
      @test !occursin("dismissal", routes(; dismissal=""))
    end

    @testset "only a metric whose findings can be wrong offers a dismissal" begin
      @test CodeRatchet.dismissal_section(Complexity()) == ""
      @test CodeRatchet.dismissal_section(Coverage()) == ""
      @test CodeRatchet.dismissal_section(Boxes()) == ""
      @test CodeRatchet.dismissal_section(Lsp()) == "lsp_dismissal"
    end

    @testset "the rise table names every offending file" begin
      table = rise_table([
        Violation("src/a.jl", "cyc", 4, 11), Violation("src/b.jl", "cog", 1, 2)
      ])
      @test occursin("| src/a.jl | cyc | 4 | 11 |", table)
      @test occursin("| src/b.jl | cog | 1 | 2 |", table)
    end

    @testset "the refresh artifact is the file a contributor commits" begin
      root = gitrepo(Dict("src/a.jl" => "f(x) = x\n"); rulings=SRC_ONLY)
      refresh(Complexity(), root)
      path = write_artifact(Complexity(), root, ratchet_dir(root))
      @test isfile(path)
      @test occursin("_refresh", path)
      @test read(path, String) ==
        read(joinpath(ratchet_dir(root), "complexity_baseline.toml"), String)
    end
  end

  @testset "baseline round trip" begin
    root = gitrepo(Dict("src/a.jl" => "f() = 1\n"); rulings=SRC_ONLY)
    dir = ratchet_dir(root)
    rows = Dict("src/a.jl" => fake(3, 30), "src/b with space.jl" => fake(4, 40))
    write(joinpath(dir, "fake_baseline.toml"), render_baseline(Fake(), rows, root))
    back, prov = read_baseline(Fake(), dir)
    @test back == rows
    @test prov["binding"] == ["bind"]
  end

  @testset "a missing rulings file is an error" begin
    @test_throws ErrorException read_rulings(mktempdir())
  end

  include("style_metric.jl")
  include("boxes_metric.jl")
  include("lsp_metric.jl")
  include("jet_metric.jl")
end
