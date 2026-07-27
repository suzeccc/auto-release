$ErrorActionPreference = "Stop"
$caseDirectory = Join-Path $PSScriptRoot "cases"
$cases = @("00-core.ps1", "10-release-runner.ps1", "20-ignore.ps1", "30-project-profiles.ps1", "40-operations.ps1", "50-release-e2e.ps1", "60-static-contract.ps1")
foreach ($case in $cases) {
  $casePath = Join-Path $caseDirectory $case
  if (-not (Test-Path -LiteralPath $casePath -PathType Leaf)) { throw "Contract case missing: $casePath" }
  . $casePath
}
