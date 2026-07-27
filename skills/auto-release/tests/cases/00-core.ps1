# Auto Release contract case: 00-core.ps1
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$skill = Get-Content -Raw -Encoding UTF8 (Join-Path $root "SKILL.md")
$script = Join-Path $root "scripts\release.ps1"
$releaseGitHubScript = Join-Path $root "scripts\release-github.ps1"
$releaseBuildScript = Join-Path $root "scripts\release-build.ps1"
$setupScript = Join-Path $root "scripts\setup-project.ps1"
$setupProfilesScript = Join-Path $root "scripts\project-profiles.ps1"
$setupGenerationScript = Join-Path $root "scripts\project-generation.ps1"
$invokeScript = Join-Path $root "scripts\invoke-release.ps1"
$invokeCommitScript = Join-Path $root "scripts\commit-transaction.ps1"
$invokeBuildScript = Join-Path $root "scripts\local-build-state.ps1"
$commitStyleScript = Join-Path $root "scripts\commit-style.ps1"
$ignoreScript = Join-Path $root "scripts\ignore-audit.ps1"
$ignoreGitScript = Join-Path $root "scripts\ignore-git.ps1"
$ignoreCandidatesScript = Join-Path $root "scripts\ignore-candidates.ps1"
$utils = Join-Path $root "scripts\release-utils.ps1"
$reference = Join-Path $root "references\config.md"
$ignoreReference = Join-Path $root "references\ignore.md"
$workflowTemplates = @(
  Join-Path $root "assets\workflows\tauri.yml"
  Join-Path $root "assets\workflows\node.yml"
  Join-Path $root "assets\workflows\go.yml"
  Join-Path $root "assets\workflows\python.yml"
  Join-Path $root "assets\workflows\rust.yml"
  Join-Path $root "assets\workflows\dotnet.yml"
  Join-Path $root "assets\workflows\java.yml"
  Join-Path $root "assets\workflows\cmake.yml"
  Join-Path $root "assets\workflows\flutter.yml"
  Join-Path $root "assets\workflows\android.yml"
  Join-Path $root "assets\workflows\electron.yml"
  Join-Path $root "assets\workflows\docker.yml"
)

function Assert-Match([string]$Value, [string]$Pattern, [string]$Message) {
  if ($Value -notmatch $Pattern) { throw $Message }
}

function Assert-Equal($Actual, $Expected, [string]$Message) {
  if ($Actual -ne $Expected) {
    throw "$Message. Expected: $Expected; Actual: $Actual"
  }
}

function Assert-Throws([scriptblock]$Action, [string]$Pattern, [string]$Message) {
  try {
    & $Action
  }
  catch {
    if ($_.Exception.Message -notmatch $Pattern) {
      throw "$Message. Unexpected error: $($_.Exception.Message)"
    }
    return
  }
  throw "$Message. Expected an exception"
}

function Remove-TestDirectory([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return }
  $resolved = [IO.Path]::GetFullPath($Path)
  $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
  if (
    -not $resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
    [IO.Path]::GetFileName($resolved) -notlike "auto-release-*"
  ) {
    throw "Refusing to remove unexpected test path: $resolved"
  }
  Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
}

function New-TestDirectory([string]$Label) {
  $path = Join-Path ([IO.Path]::GetTempPath()) ("auto-release-$Label-" + [guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Path $path | Out-Null
  & git -C $path init --initial-branch=main | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "git init failed for $Label fixture" }
  return $path
}

function Write-TestUtf8([string]$Path, [string]$Content) {
  $directory = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
  }
  try {
    [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
  }
  catch {
    throw "Failed to write test fixture '$Path': $($_.Exception.Message)"
  }
}

foreach ($path in @($script, $releaseGitHubScript, $releaseBuildScript, $setupScript, $setupProfilesScript, $setupGenerationScript, $invokeScript, $invokeCommitScript, $invokeBuildScript, $commitStyleScript, $ignoreScript, $ignoreGitScript, $ignoreCandidatesScript, $utils, $reference, $ignoreReference) + $workflowTemplates) {
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw "Required skill file missing: $path"
  }
}

. $utils
$scriptSource = (Get-Content -Raw -Encoding UTF8 $script) + "`n" + (Get-Content -Raw -Encoding UTF8 $releaseGitHubScript) + "`n" + (Get-Content -Raw -Encoding UTF8 $releaseBuildScript)
$referenceSource = Get-Content -Raw -Encoding UTF8 $reference
$releaseReferenceSource = Get-Content -Raw -Encoding UTF8 (Join-Path $root "references\release.md")

$runJson = @'
[
  {"databaseId":3001,"headBranch":"v1.2.3","headSha":"target-sha","status":"in_progress","url":"https://example.invalid/runs/3001"},
  {"databaseId":3002,"headBranch":"v1.2.3","headSha":"other-sha","status":"completed","url":"https://example.invalid/runs/3002"}
]
'@
$selectedRun = Select-WorkflowRun -Json $runJson -Tag "v1.2.3" -HeadSha "target-sha"
Assert-Equal @($selectedRun).Count 1 "workflow selection returned multiple objects"
Assert-Equal ([string]$selectedRun.databaseId) "3001" "wrong workflow ID"
Assert-Equal (Select-WorkflowRun -Json $runJson -Tag "v9.9.9" -HeadSha "missing") $null "missing run must return null"

$waitingRun = '{"status":"in_progress","conclusion":"","jobs":[{"name":"Build","status":"in_progress","conclusion":""}]}' | ConvertFrom-Json
$waitingSnapshot = Get-WorkflowRunSnapshot -Run $waitingRun
Assert-Equal $waitingSnapshot.State "Waiting" "active job must wait"
Assert-Equal (Test-WorkflowSnapshotChanged -PreviousSignature $waitingSnapshot.Signature -Snapshot $waitingSnapshot) $false "same state must not print twice"

$failedRun = '{"status":"in_progress","conclusion":"","jobs":[{"name":"Build","status":"completed","conclusion":"failure"}]}' | ConvertFrom-Json
$failedSnapshot = Get-WorkflowRunSnapshot -Run $failedRun
Assert-Equal $failedSnapshot.State "Failed" "terminal job failure must stop waiting"
Assert-Match $failedSnapshot.Message "Build.*failure" "failure must identify the job"

$successRun = '{"status":"completed","conclusion":"success","jobs":[{"name":"Build","status":"completed","conclusion":"success"}]}' | ConvertFrom-Json
$successSnapshot = Get-WorkflowRunSnapshot -Run $successRun
Assert-Equal $successSnapshot.State "Succeeded" "successful workflow must complete"

$updatesHeading =
  ([char]0x66F4).ToString() +
  ([char]0x65B0).ToString() +
  ([char]0x5185).ToString() +
  ([char]0x5BB9).ToString()
$newLabel = ([char]0x65B0).ToString() + ([char]0x589E).ToString()
$fixLabel = ([char]0x4FEE).ToString() + ([char]0x590D).ToString()
$validNotes = @(
  "## $updatesHeading",
  "",
  "- ${newLabel}: user-visible capability.",
  "- ${fixLabel}: release blocker."
) -join [Environment]::NewLine
Assert-ReleaseNotes -ReleaseNotes $validNotes -Heading "## $updatesHeading" -MinItems 2 -MaxItems 6 -RequireChinese $true
Assert-Throws {
  Assert-ReleaseNotes -ReleaseNotes "one-line summary" -Heading "## Changes" -MinItems 2 -MaxItems 6
} "must contain heading" "missing release heading must fail"
Assert-Throws {
  Assert-ReleaseNotes -ReleaseNotes "## Changes`n`n- one" -Heading "## Changes" -MinItems 2 -MaxItems 6
} "2 to 6" "too few release-note items must fail"

$conventionalAnalysis = Get-CommitStyleAnalysis -Subjects @(
  "feat: add search",
  "fix(api): handle empty input",
  "docs: update usage",
  "chore: refresh dependencies"
)
Assert-Equal $conventionalAnalysis.selectedStyle "conventional" "Conventional commit style was not detected"
Assert-Equal $conventionalAnalysis.reason "required" "Conventional format was not reported as required"
Assert-Equal $conventionalAnalysis.policy "conventional" "Conventional policy was not normalized"

$plainAnalysis = Get-CommitStyleAnalysis -Policy auto -Subjects @(
  "Improve search",
  "Fix empty input",
  "Update usage",
  "Refresh dependencies"
)
Assert-Equal $plainAnalysis.selectedStyle "conventional" "Plain history changed the required Conventional format"
Assert-Equal $plainAnalysis.reason "legacy-policy-normalized" "Legacy auto policy was not normalized"

$legacyOffAnalysis = Get-CommitStyleAnalysis -Policy off -Subjects @(
  "feat: add search",
  "[fix] handle empty input",
  "PROJ-123 update usage",
  "Refresh dependencies"
)
Assert-Equal $legacyOffAnalysis.selectedStyle "conventional" "Legacy off policy disabled Conventional validation"
Assert-Equal $legacyOffAnalysis.configuredPolicy "off" "Legacy policy value was not preserved for diagnostics"
Assert-Equal $legacyOffAnalysis.reason "legacy-policy-normalized" "Legacy off policy did not report normalization"

$requiredAnalysis = Get-CommitStyleAnalysis -Policy conventional -Subjects @("Initial project")
Assert-CommitSummaryStyle -Summary "chore: update project" -Analysis $requiredAnalysis
Assert-CommitSummaryStyle -Summary "fix(auth): handle login failure" -Analysis $requiredAnalysis
Assert-CommitSummaryStyle -Summary "feat(api)!: remove legacy endpoint" -Analysis $requiredAnalysis
foreach ($invalidSummary in @("Update project", "[fix] update project", "PROJ-123 update project", ":sparkles: update project")) {
  Assert-Throws {
    Assert-CommitSummaryStyle -Summary $invalidSummary -Analysis $requiredAnalysis
  } "must follow Conventional Commits" "Accepted a non-Conventional summary: $invalidSummary"
}

$chineseLanguage = Get-CommitLanguageAnalysis -PromptLanguage Chinese
Assert-Equal $chineseLanguage.selectedLanguage "Chinese" "Chinese prompt language was not selected"
Assert-Equal $chineseLanguage.reason "prompt" "Explicit Chinese prompt language used the wrong source"
Assert-CommitSummaryLanguage -Summary "feat: $newLabel prompt language" -Analysis $chineseLanguage
Assert-Throws {
  Assert-CommitSummaryLanguage -Summary "feat: add prompt language" -Analysis $chineseLanguage
} "must be Chinese" "Chinese prompt language accepted an English description"

$englishLanguage = Get-CommitLanguageAnalysis -PromptLanguage English
Assert-CommitSummaryLanguage -Summary "feat: add prompt language" -Analysis $englishLanguage
Assert-Throws {
  Assert-CommitSummaryLanguage -Summary "feat: $newLabel prompt language" -Analysis $englishLanguage
} "must be English" "English prompt language accepted a Chinese description"

$autoChineseLanguage = Get-CommitLanguageAnalysis -PromptLanguage Auto -Subjects @(
  "feat: $newLabel search",
  "fix: $newLabel empty input",
  "docs: $newLabel usage"
)
Assert-Equal $autoChineseLanguage.selectedLanguage "Chinese" "Auto language did not follow Chinese repository history"
Assert-Equal $autoChineseLanguage.reason "repository-history" "Auto language reported the wrong history reason"
$autoEnglishLanguage = Get-CommitLanguageAnalysis -PromptLanguage Auto -Subjects @(
  "feat: add search",
  "fix: handle empty input",
  "docs: update usage"
)
Assert-Equal $autoEnglishLanguage.selectedLanguage "English" "Auto language did not follow English repository history"
$autoTieLanguage = Get-CommitLanguageAnalysis -PromptLanguage Auto -MinimumSamples 2 -Subjects @(
  "feat: $newLabel search",
  "fix: handle empty input"
)
Assert-Equal $autoTieLanguage.selectedLanguage "English" "Indeterminate Auto language did not use the documented fallback"
Assert-Equal $autoTieLanguage.reason "mixed-tie" "Indeterminate Auto language reported the wrong fallback reason"

$parallelRoot = Join-Path ([IO.Path]::GetTempPath()) ("auto-release-parallel-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $parallelRoot | Out-Null
$shell = (Get-Process -Id $PID).Path
try {
  $worker = @'
param([string]$OwnMarker, [string]$OtherMarker)
New-Item -ItemType File -Path $OwnMarker -Force | Out-Null
$deadline = [DateTime]::UtcNow.AddSeconds(5)
while (-not (Test-Path -LiteralPath $OtherMarker)) {
  if ([DateTime]::UtcNow -ge $deadline) { exit 9 }
  Start-Sleep -Milliseconds 50
}
'@
  [IO.File]::WriteAllText((Join-Path $parallelRoot "a.ps1"), $worker)
  [IO.File]::WriteAllText((Join-Path $parallelRoot "b.ps1"), $worker)
  $quotedShell = '"' + $shell + '"'
  Invoke-ParallelShellChecked -WorkingDirectory $parallelRoot -Commands @(
    @{ name = "worker-a"; command = "$quotedShell -NoProfile -File a.ps1 a.marker b.marker" },
    @{ name = "worker-b"; command = "$quotedShell -NoProfile -File b.ps1 b.marker a.marker" }
  )

  [IO.File]::WriteAllText((Join-Path $parallelRoot "fail.ps1"), "exit 7")
  [IO.File]::WriteAllText(
    (Join-Path $parallelRoot "slow.ps1"),
    'Start-Sleep -Seconds 10; New-Item -ItemType File -Path "leaked.marker" | Out-Null'
  )
  Assert-Throws {
    Invoke-ParallelShellChecked -WorkingDirectory $parallelRoot -Commands @(
      @{ name = "worker-fail"; command = "$quotedShell -NoProfile -File fail.ps1" },
      @{ name = "worker-slow"; command = "$quotedShell -NoProfile -File slow.ps1" }
    )
  } "worker-fail.*exit code 7" "parallel failure must identify the original command"
  Start-Sleep -Milliseconds 1500
  if (Test-Path -LiteralPath (Join-Path $parallelRoot "leaked.marker")) {
    throw "parallel failure left a child process running"
  }
}
finally {
  Remove-TestDirectory $parallelRoot
}
