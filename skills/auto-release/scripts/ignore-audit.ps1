[CmdletBinding()]
param(
  [ValidateSet("Audit", "Apply", "ApplyAndUntrack")]
  [string]$Mode = "Audit",

  [string]$RepositoryRoot = (Get-Location).Path,

  [string]$PlanPath,

  [switch]$NoWritePlan,

  [ValidateSet("Human", "Json")]
  [string]$OutputFormat = "Human"
)

$ErrorActionPreference = "Stop"
$script:Utf8NoBom = [Text.UTF8Encoding]::new($false)
$script:Root = $null
$script:GitDirectory = $null
$script:Candidates = @()
$script:CandidatePatterns = @{}
$script:SkillRoots = @()
$script:BeginMarker = "# BEGIN Auto Release managed ignores"
$script:EndMarker = "# END Auto Release managed ignores"
$ignoreGitScript = Join-Path $PSScriptRoot "ignore-git.ps1"
if (-not (Test-Path -LiteralPath $ignoreGitScript -PathType Leaf)) { throw "Ignore Git module missing: $ignoreGitScript" }
. $ignoreGitScript
$ignoreCandidateScript = Join-Path $PSScriptRoot "ignore-candidates.ps1"
if (-not (Test-Path -LiteralPath $ignoreCandidateScript -PathType Leaf)) { throw "Ignore candidate module missing: $ignoreCandidateScript" }
. $ignoreCandidateScript

function Get-PortableLeafName([string]$Path) {
  $normalized = $Path.Replace("\", "/").TrimEnd("/")
  if ([string]::IsNullOrEmpty($normalized)) { return "" }
  return @($normalized -split "/")[-1]
}

function Get-NormalizedPath([string]$Path) {
  return [IO.Path]::GetFullPath($Path).TrimEnd(
    [IO.Path]::DirectorySeparatorChar,
    [IO.Path]::AltDirectorySeparatorChar
  )
}

function Initialize-Context {
  if (-not (Test-Path -LiteralPath $RepositoryRoot -PathType Container)) {
    throw "Repository root not found: $RepositoryRoot"
  }
  $script:Root = Get-NormalizedPath (Resolve-Path -LiteralPath $RepositoryRoot).Path
  $gitRootResult = Invoke-GitCaptured @("rev-parse", "--show-toplevel")
  $gitRoot = Get-NormalizedPath $gitRootResult.Output
  if (-not $gitRoot.Equals($script:Root, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Repository root mismatch: $gitRoot"
  }
  $gitDirectory = (Invoke-GitCaptured @("rev-parse", "--git-dir")).Output
  if (-not [IO.Path]::IsPathRooted($gitDirectory)) { $gitDirectory = Join-Path $script:Root $gitDirectory }
  $script:GitDirectory = Get-NormalizedPath $gitDirectory
}

function Get-ResolvedPlanPath {
  $path = if ([string]::IsNullOrWhiteSpace($PlanPath)) {
    Join-Path $script:GitDirectory "auto-release\ignore-plan.json"
  }
  elseif ([IO.Path]::IsPathRooted($PlanPath)) {
    [IO.Path]::GetFullPath($PlanPath)
  }
  else {
    [IO.Path]::GetFullPath((Join-Path $script:Root $PlanPath))
  }
  $prefix = $script:GitDirectory + [IO.Path]::DirectorySeparatorChar
  if (-not $path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Ignore plan must be stored under the Git directory: $script:GitDirectory"
  }
  return $path
}

function Get-RepositoryRelativePath([string]$Path) {
  $fullPath = [IO.Path]::GetFullPath($Path)
  $prefix = $script:Root + [IO.Path]::DirectorySeparatorChar
  if (-not $fullPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Path escapes repository root: $Path"
  }
  return $fullPath.Substring($prefix.Length).Replace("\", "/")
}

function Get-WorktreeFingerprint {
  $head = (Invoke-GitCaptured @("rev-parse", "HEAD")).Output
  $status = (Invoke-GitRaw @("-c", "core.quotepath=false", "status", "--porcelain=v1", "-z", "--untracked-files=all")).Output
  $payload = $script:Utf8NoBom.GetBytes("$head`0$status")
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return ([BitConverter]::ToString($sha.ComputeHash($payload))).Replace("-", "") }
  finally { $sha.Dispose() }
}

function New-IgnorePlan {
  $script:Candidates = @()
  $script:CandidatePatterns = @{}
  $script:SkillRoots = @(Get-CodexSkillRoots)
  $projectTypes = @(Get-DetectedProjectTypes)
  Add-CommonCandidates
  Add-AgentCandidates
  Add-LocalArtifactCandidates
  Add-ProjectCandidates $projectTypes
  $trackedPaths = @(Get-GitPathList @("ls-files"))
  $untrackedPaths = @(Get-GitPathList @("ls-files", "--others", "--exclude-standard"))
  $ignoredSensitivePaths = @(Get-IgnoredSensitivePaths)
  $currentPaths = @($trackedPaths + $untrackedPaths + $ignoredSensitivePaths | Sort-Object -Unique)
  $rules = @()
  $alreadyCovered = @()
  $review = @()
  $untrackPaths = @()
  foreach ($candidate in $script:Candidates) {
    $trackedMatches = @($trackedPaths | Where-Object { Test-PathMatches $candidate $_ })
    $untrackedMatches = @($untrackedPaths | Where-Object { Test-PathMatches $candidate $_ })
    $referenced = if ($trackedMatches.Count -gt 0) { Test-CandidateReferenced $candidate } else { $false }
    $classification = if ([double]$candidate.confidence -lt 0.8) {
      "review"
    }
    elseif ($trackedMatches.Count -gt 0 -and (-not [bool]$candidate.allowTrackedIfUnreferenced -or $referenced)) {
      "review"
    }
    else {
      "safe"
    }
    $candidateMatches = @($trackedMatches + $untrackedMatches | Sort-Object -Unique)
    $covered = Test-CandidateCovered $candidate $candidateMatches
    $matchedBytes = [long]0
    foreach ($matchPath in $candidateMatches) {
      $fullPath = Join-Path $script:Root $matchPath
      if (Test-Path -LiteralPath $fullPath -PathType Leaf) { $matchedBytes += (Get-Item -LiteralPath $fullPath).Length }
    }
    $record = [pscustomobject][ordered]@{
      pattern = [string]$candidate.pattern
      samplePath = [string]$candidate.samplePath
      category = [string]$candidate.category
      reason = [string]$candidate.reason
      confidence = [double]$candidate.confidence
      trackedMatches = $trackedMatches
      untrackedMatches = $untrackedMatches
      matchedBytes = $matchedBytes
      referenced = $referenced
    }
    if ($classification -eq "safe") {
      $untrackPaths += $trackedMatches
      if ($covered) { $alreadyCovered += $record } else { $rules += $record }
    }
    else {
      $review += $record
    }
  }
  $ignoreFiles = @($trackedPaths + $untrackedPaths | Where-Object { (Get-PortableLeafName $_) -eq ".gitignore" } | Sort-Object -Unique)
  $sensitivePaths = @(Get-SensitivePaths $currentPaths)
  return [pscustomobject][ordered]@{
    schemaVersion = 1
    baseHead = (Invoke-GitCaptured @("rev-parse", "HEAD")).Output
    worktreeFingerprint = Get-WorktreeFingerprint
    repositoryRoot = $script:Root
    ignoreFile = ".gitignore"
    detectedProjectTypes = $projectTypes
    detectedSkillRoots = $script:SkillRoots
    ignoreFiles = $ignoreFiles
    rules = $rules
    alreadyCovered = $alreadyCovered
    review = $review
    untrackPaths = @($untrackPaths | Sort-Object -Unique)
    trackedButIgnored = @(Get-TrackedButIgnored $trackedPaths)
    sensitivePaths = $sensitivePaths
    protectedPaths = @(Get-ProtectedPaths $trackedPaths $script:SkillRoots)
    historicalGeneratedPaths = @(Get-HistoricalGeneratedPaths $script:Candidates)
  }
}

function Write-AtomicText([string]$Path, [string]$Text) {
  $directory = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
  }
  $temporary = Join-Path $directory (".auto-release-" + [guid]::NewGuid().ToString("N") + ".tmp")
  try {
    [IO.File]::WriteAllText($temporary, $Text, $script:Utf8NoBom)
    Move-Item -LiteralPath $temporary -Destination $Path -Force
  }
  finally {
    if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force }
  }
}

function Save-Plan($Plan) {
  $path = Get-ResolvedPlanPath
  Write-AtomicText $path (($Plan | ConvertTo-Json -Depth 20) + "`n")
  return $path
}

function Read-Plan {
  $path = Get-ResolvedPlanPath
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Ignore plan not found; run Ignore Audit first: $path" }
  try { $plan = Get-Content -Raw -Encoding UTF8 -LiteralPath $path | ConvertFrom-Json }
  catch { throw "Ignore plan is invalid JSON: $path" }
  if ([int]$plan.schemaVersion -ne 1) { throw "Ignore plan schemaVersion must be 1" }
  if ([string]$plan.baseHead -ne (Invoke-GitCaptured @("rev-parse", "HEAD")).Output) { throw "Ignore plan baseHead is stale; run Audit again" }
  if ([string]$plan.worktreeFingerprint -ne (Get-WorktreeFingerprint)) { throw "Ignore plan worktree fingerprint is stale; run Audit again" }
  return $plan
}

function Get-ManagedIgnoreText($Plan, [string]$ExistingText) {
  $beginCount = ([regex]::Matches($ExistingText, [regex]::Escape($script:BeginMarker))).Count
  $endCount = ([regex]::Matches($ExistingText, [regex]::Escape($script:EndMarker))).Count
  if ($beginCount -ne $endCount -or $beginCount -gt 1) { throw "Malformed Auto Release managed ignore markers" }
  if ($beginCount -eq 1 -and $ExistingText.IndexOf($script:BeginMarker, [StringComparison]::Ordinal) -gt $ExistingText.IndexOf($script:EndMarker, [StringComparison]::Ordinal)) {
    throw "Malformed Auto Release managed ignore markers: END appears before BEGIN"
  }
  $patternsByCategory = [ordered]@{}
  foreach ($rule in @($Plan.rules)) {
    $category = [string]$rule.category
    if (-not $patternsByCategory.Contains($category)) { $patternsByCategory[$category] = @() }
    $patternsByCategory[$category] += [string]$rule.pattern
  }
  $rulePatterns = @($Plan.rules | ForEach-Object { [string]$_.pattern })
  if ($rulePatterns -contains ".env" -or $rulePatterns -contains ".env.*") {
    if (-not $patternsByCategory.Contains("Secrets")) { $patternsByCategory["Secrets"] = @() }
    $patternsByCategory["Secrets"] += "!.env.example"
  }
  $existingLines = @{}
  foreach ($line in @($ExistingText -split "`r?`n")) { $existingLines[$line.Trim()] = $true }
  $addition = @()
  foreach ($category in $patternsByCategory.Keys) {
    $uniquePatterns = @($patternsByCategory[$category] | Sort-Object -Unique)
    $orderedPatterns = @($uniquePatterns | Where-Object { -not $_.StartsWith("!") }) + @($uniquePatterns | Where-Object { $_.StartsWith("!") })
    $missingPatterns = @($orderedPatterns | Where-Object { -not $existingLines.ContainsKey($_) })
    if ($missingPatterns.Count -eq 0) { continue }
    $addition += ""
    $addition += "# $category"
    $addition += $missingPatterns
  }
  if ($beginCount -eq 1) {
    if ($addition.Count -eq 0) { return $ExistingText }
    $replacement = (($addition -join "`n") + "`n" + $script:EndMarker)
    return $ExistingText.Replace($script:EndMarker, $replacement)
  }
  $body = @($script:BeginMarker) + $addition + @($script:EndMarker)
  $block = $body -join "`n"
  $trimmed = $ExistingText.TrimEnd("`r", "`n")
  if ($trimmed) { return "$trimmed`n`n$block`n" }
  return "$block`n"
}

function Apply-Plan($Plan, [bool]$Untrack) {
  if (@($Plan.sensitivePaths).Count -gt 0) {
    throw "Sensitive files require manual review before ignore rules can be applied: $(@($Plan.sensitivePaths) -join ', ')"
  }
  $ignorePath = Join-Path $script:Root ".gitignore"
  $ignoreExists = Test-Path -LiteralPath $ignorePath -PathType Leaf
  $ignoreBytes = if ($ignoreExists) { [IO.File]::ReadAllBytes($ignorePath) } else { $null }
  $existingText = if ($ignoreExists) { [IO.File]::ReadAllText($ignorePath) } else { "" }
  $indexBackup = Backup-Index
  $protectedBefore = @{}
  foreach ($path in @($Plan.protectedPaths)) { $protectedBefore[[string]$path] = Test-IsIgnored ([string]$path) }
  $localSnapshot = Get-FileSnapshot @($Plan.untrackPaths)
  $rulesAdded = @($Plan.rules | ForEach-Object { [string]$_.pattern })
  try {
    if ($rulesAdded.Count -gt 0) {
      $updatedText = Get-ManagedIgnoreText $Plan $existingText
      Write-AtomicText $ignorePath $updatedText
    }
    foreach ($rule in @($Plan.rules)) {
      if (-not (Test-IsIgnored ([string]$rule.samplePath))) {
        throw "Applied ignore rule did not match its probe: $($rule.pattern)"
      }
    }
    foreach ($path in @($Plan.protectedPaths)) {
      $wasIgnored = [bool]$protectedBefore[[string]$path]
      if (-not $wasIgnored -and (Test-IsIgnored ([string]$path))) {
        throw "New ignore rules unexpectedly hide a protected path: $path"
      }
    }
    if ($Untrack) {
      foreach ($path in @($Plan.untrackPaths)) {
        if (-not (Test-IsIgnored ([string]$path))) {
          throw "Refusing to untrack a path that is not ignored by the applied rules: $path"
        }
      }
      foreach ($path in @($Plan.untrackPaths)) {
        Invoke-GitChecked @("rm", "--cached", "--ignore-unmatch", "--", [string]$path)
      }
      Assert-FileSnapshot $localSnapshot
    }
    $diffCheck = Invoke-GitCaptured @("diff", "--check") $true
    if ($diffCheck.ExitCode -ne 0) { throw "git diff --check failed: $($diffCheck.Output)" }
  }
  catch {
    if ($ignoreExists) { [IO.File]::WriteAllBytes($ignorePath, [byte[]]$ignoreBytes) }
    elseif (Test-Path -LiteralPath $ignorePath -PathType Leaf) { Remove-Item -LiteralPath $ignorePath -Force }
    Restore-Index $indexBackup
    throw
  }
  return [pscustomobject][ordered]@{
    operation = "Ignore"
    status = "succeeded"
    mode = if ($Untrack) { "ApplyAndUntrack" } else { "Apply" }
    planPath = Get-ResolvedPlanPath
    rulesAdded = $rulesAdded
    untrackedPaths = if ($Untrack) { @($Plan.untrackPaths) } else { @() }
    review = @($Plan.review)
  }
}

function Write-HumanPlan($Plan, [string]$Path) {
  Write-Host "Ignore audit: $script:Root"
  Write-Host "Project types: $(@($Plan.detectedProjectTypes) -join ', ')"
  if (@($Plan.detectedSkillRoots).Count -gt 0) {
    Write-Host "Codex Skill roots: $(@($Plan.detectedSkillRoots) -join ', ')"
  }
  Write-Host "Plan: $Path"
  foreach ($rule in @($Plan.rules)) { Write-Host "Add: $($rule.pattern) - $($rule.reason)" }
  foreach ($item in @($Plan.review)) { Write-Host "Review: $($item.pattern) - $($item.reason)" }
  foreach ($pathValue in @($Plan.untrackPaths)) { Write-Host "Tracked match: $pathValue" }
  foreach ($record in @($Plan.trackedButIgnored)) { Write-Host "Tracked but ignored: $($record.path) <- $($record.pattern)" }
  foreach ($pathValue in @($Plan.sensitivePaths)) { Write-Host "Sensitive: $pathValue" }
  if (@($Plan.rules).Count -eq 0) { Write-Host "No high-confidence ignore rules are missing" }
}

function Write-Result($Result) {
  if ($OutputFormat -eq "Json") { Write-Output ($Result | ConvertTo-Json -Depth 20 -Compress) }
}

Initialize-Context
if ($Mode -eq "Audit") {
  $plan = New-IgnorePlan
  $resolvedPlanPath = Get-ResolvedPlanPath
  if (-not $NoWritePlan) { $resolvedPlanPath = Save-Plan $plan }
  $result = [pscustomobject][ordered]@{
    operation = "Ignore"
    status = "planned"
    mode = "Audit"
    whatIf = [bool]$NoWritePlan
    planPath = $resolvedPlanPath
    plan = $plan
  }
  if ($OutputFormat -eq "Human") { Write-HumanPlan $plan $resolvedPlanPath }
  Write-Result $result
  return
}

$plan = Read-Plan
$result = Apply-Plan $plan ($Mode -eq "ApplyAndUntrack")
if ($OutputFormat -eq "Human") {
  Write-Host "Ignore $Mode completed"
  Write-Host "Rules added: $(@($result.rulesAdded).Count)"
  Write-Host "Paths untracked: $(@($result.untrackedPaths).Count)"
}
Write-Result $result
