function parse_source()
  files = filter(path -> startswith(path, "src/"), CodeRatchet.tracked_julia_files(pwd()))
  isempty(files) && error("CodeRatchet source files were not found")
  isempty(CodeRatchet.parse_failures(pwd(), files)) || error("CodeRatchet source did not parse")
  return length(files)
end

function measure_complexity()
  rows = CodeRatchet.measure(
    Complexity(), pwd(); dir=joinpath(pwd(), "code_ratchet")
  )
  isempty(rows) && error("complexity measurement returned no rows")
  return sum(row["cyc"] for row in values(rows))
end

const PRECOMPILE_BENCHMARKS = (
  parse_source=parse_source,
  measure_complexity=measure_complexity,
)
