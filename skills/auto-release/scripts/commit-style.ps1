[CmdletBinding()]
param(
  [string]$RepositoryRoot = (Get-Location).Path,
  [string]$ConfigPath = ".codex-release.json",
  [string]$Summary
)

$ErrorActionPreference = "Stop"
$utilsScript = Join-Path $PSScriptRoot "release-utils.ps1"
if (-not (Test-Path -LiteralPath $utilsScript -PathType Leaf)) {
  throw "Release utilities missing: $utilsScript"
}
. $utilsScript

if (-not (Test-Path -LiteralPath $RepositoryRoot -PathType Container)) {
  throw "Repository root not found: $RepositoryRoot"
}
$root = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $RepositoryRoot).Path).TrimEnd(
  [IO.Path]::DirectorySeparatorChar,
  [IO.Path]::AltDirectorySeparatorChar
)
$gitRoot = (& git -C $root rev-parse --show-toplevel 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0) { throw "Repository is not a Git worktree: $root" }
if (-not ([IO.Path]::GetFullPath($gitRoot).TrimEnd('\', '/') -eq $root)) {
  throw "Repository root mismatch: $gitRoot"
}

$configFile = if ([IO.Path]::IsPathRooted($ConfigPath)) {
  [IO.Path]::GetFullPath($ConfigPath)
}
else {
  [IO.Path]::GetFullPath((Join-Path $root $ConfigPath))
}
$rootPrefix = $root + [IO.Path]::DirectorySeparatorChar
if (-not $configFile.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
  throw "Config path escapes repository root: $ConfigPath"
}

$commitConfig = $null
if (Test-Path -LiteralPath $configFile -PathType Leaf) {
  try { $config = Get-Content -Raw -Encoding UTF8 -LiteralPath $configFile | ConvertFrom-Json }
  catch { throw "Release config is invalid JSON: $configFile" }
  $commitConfig = Get-CommitConfigProperty $config "commit"
}

$analysis = Get-RepositoryCommitStyleAnalysis -RepositoryRoot $root -CommitConfig $commitConfig
if (-not [string]::IsNullOrWhiteSpace($Summary)) {
  if ($Summary -match "[`r`n]") { throw "Summary must be one line" }
  Assert-CommitSummaryStyle -Summary $Summary -Analysis $analysis
  $analysis | Add-Member -NotePropertyName summary -NotePropertyValue $Summary
  $analysis | Add-Member -NotePropertyName summaryValid -NotePropertyValue $true
}
$analysis | ConvertTo-Json -Depth 8
