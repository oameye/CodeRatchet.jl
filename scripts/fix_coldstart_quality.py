from pathlib import Path


def replace_once(text, old, new, label):
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected one match, found {count}")
    return text.replace(old, new, 1)


source_path = Path("src/coldstart.jl")
source = source_path.read_text()

source = replace_once(
    source,
    '''struct ColdStartEnvironment
  variant::String
  project::String
  manifest::String
end

struct ColdStartReport''',
    '''struct ColdStartEnvironment
  variant::String
  project::String
  manifest::String
end

struct ColdStartProvenance
  base::String
  head::String
  scenario_file::String
  scenario_source::String
  config_source::String
end

struct ColdStartReport''',
    "output provenance type",
)

source = replace_once(
    source,
    '''function write_coldstart_results(
  report::ColdStartReport,
  output_dir::AbstractString,
  base::AbstractString,
  head::AbstractString;
  scenario_file::AbstractString,
  scenario_source::AbstractString,
  config_source::AbstractString,
)''',
    '''function write_coldstart_results(
  report::ColdStartReport, output_dir::AbstractString, provenance::ColdStartProvenance
)''',
    "results signature",
)
source = source.replace('full_commit(base)', 'full_commit(provenance.base)')
source = source.replace('full_commit(head)', 'full_commit(provenance.head)')
source = source.replace('"config_source=", config_source', '"config_source=", provenance.config_source')
source = source.replace('"scenario_source=", scenario_source', '"scenario_source=", provenance.scenario_source')
source = source.replace('coldstart_file_hash(scenario_file)', 'coldstart_file_hash(provenance.scenario_file)')

source = replace_once(
    source,
    '''  verdicts = coldstart_verdicts(config, scenarios, builds, samples)
  report = ColdStartReport(config, scenarios, builds, samples, verdicts, environments)
  isempty(output_dir) || write_coldstart_results(
    report,
    output_dir,
    base_path,
    head_path;
    scenario_file=scenario.file,
    scenario_source=scenario.source,
    config_source=selection.source,
  )
  return report''',
    '''  verdicts = coldstart_verdicts(config, scenarios, builds, samples)
  report = ColdStartReport(config, scenarios, builds, samples, verdicts, environments)
  provenance = ColdStartProvenance(
    base_path, head_path, scenario.file, scenario.source, selection.source
  )
  isempty(output_dir) || write_coldstart_results(report, output_dir, provenance)
  return report''',
    "results caller",
)
source_path.write_text(source)


test_path = Path("test/coldstart_metric.jl")
test = test_path.read_text()

anchor = '''  @testset "scenario registry is frozen to base after bootstrap" begin'''
addition = '''  @testset "default configuration also follows base precedence" begin
    mktempdir() do root
      base = joinpath(root, "base")
      head = joinpath(root, "head")
      base_dir = joinpath(base, "code_ratchet")
      head_dir = joinpath(head, "code_ratchet")
      mkpath(base_dir)
      mkpath(head_dir)

      write(joinpath(base_dir, "rulings.toml"), "[scope]\\nmeasure = [\\\"src/\\\"]\\n")
      selection = CodeRatchet.coldstart_config_selection(base, head, "code_ratchet")
      @test selection.source == "base-default"
      @test selection.config.builds == 2

      rm(joinpath(base_dir, "rulings.toml"))
      write(joinpath(head_dir, "rulings.toml"), "[scope]\\nmeasure = [\\\"src/\\\"]\\n")
      selection = CodeRatchet.coldstart_config_selection(base, head, "code_ratchet")
      @test selection.source == "head-default"
      @test selection.config.builds == 2

      rm(joinpath(head_dir, "rulings.toml"))
      @test_throws ErrorException CodeRatchet.coldstart_config_selection(
        base, head, "code_ratchet"
      )
    end
  end

'''
test = replace_once(test, anchor, addition + anchor, "default config tests")

anchor = '''  @testset "results carry runtime and scenario provenance" begin'''
addition = '''  @testset "project identity requires string name and uuid" begin
    mktempdir() do root
      write(joinpath(root, "Project.toml"), "name = 1\\nuuid = \\\"abc\\\"\\n")
      @test_throws ErrorException CodeRatchet.project_identity(root)
      write(joinpath(root, "Project.toml"), "name = \\\"Tiny\\\"\\nuuid = 1\\n")
      @test_throws ErrorException CodeRatchet.project_identity(root)
    end
  end

'''
test = replace_once(test, anchor, addition + anchor, "project identity tests")

test = replace_once(
    test,
    '''      CodeRatchet.write_coldstart_results(
        report,
        output,
        pwd(),
        pwd();
        scenario_file,
        scenario_source="base",
        config_source="base",
      )''',
    '''      provenance = CodeRatchet.ColdStartProvenance(
        pwd(), pwd(), scenario_file, "base", "base"
      )
      CodeRatchet.write_coldstart_results(report, output, provenance)''',
    "results provenance test",
)

test_path.write_text(test)
