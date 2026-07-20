$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$skill = Get-Content -Raw -Encoding UTF8 (Join-Path $root "SKILL.md")
$script = Join-Path $root "scripts\release.ps1"
$setupScript = Join-Path $root "scripts\setup-project.ps1"
$utils = Join-Path $root "scripts\release-utils.ps1"
$reference = Join-Path $root "references\config.md"
$workflowTemplates = @(
  Join-Path $root "assets\workflows\tauri.yml"
  Join-Path $root "assets\workflows\node.yml"
  Join-Path $root "assets\workflows\go.yml"
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
    [IO.Path]::GetFileName($resolved) -notlike "project-release-automator-*"
  ) {
    throw "Refusing to remove unexpected test path: $resolved"
  }
  Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
}

function New-TestDirectory([string]$Label) {
  $path = Join-Path ([IO.Path]::GetTempPath()) ("project-release-automator-$Label-" + [guid]::NewGuid().ToString("N"))
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
  [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
}

foreach ($path in @($script, $setupScript, $utils, $reference) + $workflowTemplates) {
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw "Required skill file missing: $path"
  }
}

. $utils
$scriptSource = Get-Content -Raw -Encoding UTF8 $script
$referenceSource = Get-Content -Raw -Encoding UTF8 $reference

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

$parallelRoot = Join-Path ([IO.Path]::GetTempPath()) ("project-release-automator-parallel-" + [guid]::NewGuid().ToString("N"))
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
  Start-Sleep -Milliseconds 500
  if (Test-Path -LiteralPath (Join-Path $parallelRoot "leaked.marker")) {
    throw "parallel failure left a child process running"
  }
}
finally {
  Remove-TestDirectory $parallelRoot
}

$planRoot = Join-Path ([IO.Path]::GetTempPath()) ("project-release-automator-plan-" + [guid]::NewGuid().ToString("N"))
$bareRoot = Join-Path ([IO.Path]::GetTempPath()) ("project-release-automator-remote-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $planRoot | Out-Null
New-Item -ItemType Directory -Path $bareRoot | Out-Null
try {
  & git -C $planRoot init --initial-branch=main | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "git init failed" }
  & git -C $bareRoot init --bare | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "bare git init failed" }
  & git -C $planRoot remote add origin $bareRoot
  if ($LASTEXITCODE -ne 0) { throw "git remote add failed" }
  [IO.File]::WriteAllText(
    (Join-Path $planRoot "package.json"),
    '{"name":"example","version":"1.0.0"}',
    [Text.UTF8Encoding]::new($false)
  )
  $config = @'
{
  "schemaVersion": 1,
  "projectName": "Example",
  "branch": "main",
  "remote": "origin",
  "tagPrefix": "v",
  "version": {
    "read": {
      "path": "package.json",
      "pattern": "\\\"version\\\"\\s*:\\s*\\\"(?<version>\\d+\\.\\d+\\.\\d+)\\\""
    },
    "updates": [
      {
        "path": "package.json",
        "pattern": "(\\\"version\\\"\\s*:\\s*\\\")\\d+\\.\\d+\\.\\d+(\\\")",
        "replacement": "${1}{version}$2",
        "expectedMatches": 1
      }
    ]
  },
  "prepare": {
    "parallel": false,
    "commands": [{"name":"Check","command":"echo checked"}],
    "artifacts": []
  },
  "publish": {
    "release": {"mode":"none"}
  }
}
'@
  [IO.File]::WriteAllText(
    (Join-Path $planRoot ".codex-release.json"),
    $config,
    [Text.UTF8Encoding]::new($false)
  )
  & git -C $planRoot config user.name "Project Release Test"
  & git -C $planRoot config user.email "project-release-automator@example.invalid"
  & git -C $planRoot add package.json .codex-release.json
  & git -C $planRoot commit -m "Initial test project" | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "initial commit failed" }
  & git -C $planRoot push --set-upstream origin main | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "initial push failed" }

  $plan = & $script `
    -Mode Plan `
    -Version v1.1.0 `
    -Summary "Generic project release." `
    -RepositoryRoot $planRoot
  $planText = $plan -join [Environment]::NewLine
  Assert-Match $planText "Project: Example" "plan missing configured project name"
  Assert-Match $planText "Target version: 1\.1\.0" "plan missing target version"
  Assert-Match $planText "Prepare command: Check -> echo checked" "plan missing configured command"
  Assert-Match $planText "Release mode: none" "plan missing release strategy"

  & $script `
    -Mode Prepare `
    -Version v1.1.0 `
    -Summary "Generic project release." `
    -RepositoryRoot $planRoot
  $preparedPackage = Get-Content -Raw -Encoding UTF8 (Join-Path $planRoot "package.json") | ConvertFrom-Json
  Assert-Equal $preparedPackage.version "1.1.0" "Prepare did not apply the configured version update"

  $schema2Config = Get-Content -Raw -Encoding UTF8 (Join-Path $planRoot ".codex-release.json") | ConvertFrom-Json
  $schema2Config.schemaVersion = 2
  Write-TestUtf8 `
    (Join-Path $planRoot ".codex-release.json") `
    (($schema2Config | ConvertTo-Json -Depth 20) + "`n")
  $schema2Plan = & $script `
    -Mode Plan `
    -Version v1.1.0 `
    -Summary "Generic project release." `
    -RepositoryRoot $planRoot
  Assert-Match ($schema2Plan -join [Environment]::NewLine) "Project: Example" "release runner rejected schema v2"
}
finally {
  Remove-TestDirectory $planRoot
  Remove-TestDirectory $bareRoot
}

$nodeRoot = New-TestDirectory "node"
try {
  Write-TestUtf8 (Join-Path $nodeRoot "package.json") @'
{
  "name": "node-fixture",
  "version": "1.2.3",
  "scripts": {
    "test": "node --test",
    "build": "node build.js"
  }
}
'@
  Write-TestUtf8 (Join-Path $nodeRoot "package-lock.json") @'
{
  "name": "node-fixture",
  "version": "1.2.3",
  "lockfileVersion": 3,
  "packages": {
    "": {
      "name": "node-fixture",
      "version": "1.2.3"
    }
  }
}
'@
  $nodeDetection = (& $setupScript -Mode Detect -RepositoryRoot $nodeRoot) | ConvertFrom-Json
  Assert-Equal $nodeDetection.projectType "node" "Node fixture was not detected"
  Assert-Equal $nodeDetection.packageManager "npm" "Node package manager was not detected"
  if (Test-Path -LiteralPath (Join-Path $nodeRoot ".codex-release.json")) {
    throw "Detect mode wrote a release config"
  }
  & $setupScript -Mode Generate -RepositoryRoot $nodeRoot
  & $setupScript -Mode Validate -RepositoryRoot $nodeRoot
  $nodeConfigPath = Join-Path $nodeRoot ".codex-release.json"
  $nodeWorkflowPath = Join-Path $nodeRoot ".github\workflows\release.yml"
  $nodeConfig = Get-Content -Raw -Encoding UTF8 $nodeConfigPath | ConvertFrom-Json
  Assert-Equal $nodeConfig.schemaVersion 2 "Node config does not use schema v2"
  Assert-Equal $nodeConfig.automation.template "node-v1" "Node config uses the wrong template"
  Assert-Equal @($nodeConfig.version.updates).Count 3 "Node config did not constrain all root version entries"
  $nodeConfigHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $nodeConfigPath).Hash
  $nodeWorkflowHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $nodeWorkflowPath).Hash
  & $setupScript -Mode Generate -RepositoryRoot $nodeRoot
  Assert-Equal (Get-FileHash -Algorithm SHA256 -LiteralPath $nodeConfigPath).Hash $nodeConfigHash "Node config generation is not idempotent"
  Assert-Equal (Get-FileHash -Algorithm SHA256 -LiteralPath $nodeWorkflowPath).Hash $nodeWorkflowHash "Node workflow generation is not idempotent"
}
finally {
  Remove-TestDirectory $nodeRoot
}

$tauriRoot = New-TestDirectory "tauri"
try {
  Write-TestUtf8 (Join-Path $tauriRoot "src-tauri\tauri.conf.json") @'
{
  "productName": "Tauri Fixture",
  "version": "2.3.4",
  "identifier": "invalid.example.fixture"
}
'@
  Write-TestUtf8 (Join-Path $tauriRoot "src-tauri\Cargo.toml") @'
[package]
name = "tauri-fixture"
version = "2.3.4"
edition = "2021"
'@
  Write-TestUtf8 (Join-Path $tauriRoot "src-tauri\Cargo.lock") @'
version = 4

[[package]]
name = "tauri-fixture"
version = "2.3.4"
'@
  Write-TestUtf8 (Join-Path $tauriRoot "package.json") @'
{
  "name": "tauri-fixture",
  "version": "2.3.4",
  "scripts": {
    "tauri": "tauri",
    "test": "vitest"
  }
}
'@
  Write-TestUtf8 (Join-Path $tauriRoot "pnpm-lock.yaml") "lockfileVersion: '9.0'`n"
  $tauriDetection = (& $setupScript -Mode Detect -RepositoryRoot $tauriRoot) | ConvertFrom-Json
  Assert-Equal $tauriDetection.projectType "tauri" "Tauri fixture was not detected with highest priority"
  Assert-Equal $tauriDetection.packageManager "pnpm" "Tauri package manager was not detected"
  & $setupScript -Mode Generate -RepositoryRoot $tauriRoot
  & $setupScript -Mode Validate -RepositoryRoot $tauriRoot
  $tauriConfig = Get-Content -Raw -Encoding UTF8 (Join-Path $tauriRoot ".codex-release.json") | ConvertFrom-Json
  Assert-Equal $tauriConfig.automation.template "tauri-v1" "Tauri config uses the wrong template"
  Assert-Equal @($tauriConfig.publish.release.requiredAssets).Count 6 "Tauri config does not validate all platform bundles"
  $tauriWorkflow = Get-Content -Raw -Encoding UTF8 (Join-Path $tauriRoot ".github\workflows\release.yml")
  Assert-Match $tauriWorkflow 'windows-11-arm' "Tauri workflow is missing Windows ARM64"
  Assert-Match $tauriWorkflow 'x86_64-apple-darwin' "Tauri workflow is missing macOS Intel"
  Assert-Match $tauriWorkflow 'aarch64-apple-darwin' "Tauri workflow is missing macOS Apple Silicon"
  Assert-Match $tauriWorkflow 'x86_64-unknown-linux-gnu' "Tauri workflow is missing Linux"
}
finally {
  Remove-TestDirectory $tauriRoot
}

$goRoot = New-TestDirectory "go"
try {
  Write-TestUtf8 (Join-Path $goRoot "go.mod") "module example.invalid/team/go-fixture`n`ngo 1.24`n"
  Write-TestUtf8 (Join-Path $goRoot "cmd\go-fixture\main.go") "package main`n`nfunc main() {}`n"
  $goDetection = (& $setupScript -Mode Detect -RepositoryRoot $goRoot) | ConvertFrom-Json
  Assert-Equal $goDetection.projectType "go" "Go fixture was not detected"
  Assert-Equal $goDetection.buildPath "./cmd/go-fixture" "Go command build path was not detected"
  & $setupScript -Mode Generate -RepositoryRoot $goRoot
  & $setupScript -Mode Validate -RepositoryRoot $goRoot
  Assert-Equal ([IO.File]::ReadAllText((Join-Path $goRoot "VERSION")).Trim()) "0.1.0" "Go VERSION default is wrong"
  $goConfig = Get-Content -Raw -Encoding UTF8 (Join-Path $goRoot ".codex-release.json") | ConvertFrom-Json
  Assert-Equal $goConfig.automation.template "go-v1" "Go config uses the wrong template"
  Assert-Equal @($goConfig.publish.release.requiredAssets).Count 6 "Go config does not validate six release assets"
}
finally {
  Remove-TestDirectory $goRoot
}

$ambiguousRoot = New-TestDirectory "ambiguous"
try {
  Write-TestUtf8 (Join-Path $ambiguousRoot "package.json") '{"name":"ambiguous","version":"1.0.0"}'
  Write-TestUtf8 (Join-Path $ambiguousRoot "go.mod") "module example.invalid/ambiguous`n`ngo 1.24`n"
  Assert-Throws {
    & $setupScript -Mode Detect -RepositoryRoot $ambiguousRoot
  } "detection is ambiguous" "Mixed Node and Go project must require an explicit project type"
}
finally {
  Remove-TestDirectory $ambiguousRoot
}

$humanWorkflowRoot = New-TestDirectory "human-workflow"
try {
  Write-TestUtf8 (Join-Path $humanWorkflowRoot "package.json") '{"name":"protected","version":"1.0.0"}'
  Write-TestUtf8 (Join-Path $humanWorkflowRoot ".github\workflows\release.yml") @'
name: Human Release
on: workflow_dispatch
jobs: {}
'@
  Assert-Throws {
    & $setupScript -Mode Generate -RepositoryRoot $humanWorkflowRoot
  } "Refusing to overwrite human-managed workflow" "Generator overwrote a human workflow"
  if (Test-Path -LiteralPath (Join-Path $humanWorkflowRoot ".codex-release.json")) {
    throw "Generator wrote config before checking the workflow conflict"
  }
}
finally {
  Remove-TestDirectory $humanWorkflowRoot
}

Assert-Match $scriptSource '\.codex-release\.json' "script does not use repository config"
Assert-Match $scriptSource 'remoteUrlPattern' "script does not validate configured remote"
Assert-Match $scriptSource 'git.*push|"push"' "script does not push releases"
Assert-Match $scriptSource '"--atomic"' "script does not use atomic push"
Assert-Match $scriptSource 'Local tag already exists' "missing local tag guard"
Assert-Match $scriptSource 'Remote tag already exists' "missing remote tag guard"
Assert-Match $scriptSource 'ahead or diverged' "missing remote divergence guard"
Assert-Match $scriptSource 'Release is already public' "missing public release guard"
Assert-Match $scriptSource 'gh\.exe' "missing GitHub CLI fallback"
Assert-Match $scriptSource 'Invoke-ParallelShellChecked' "missing parallel prepare support"
Assert-Match $scriptSource 'publish-draft.*create.*none' "missing release modes"
Assert-Match $scriptSource 'schemaVersion -notin @\(1, 2\)' "release runner does not accept schema v1 and v2"
if ($scriptSource -match 'D:\\QiLin|CopyShare|suzeccc') {
  throw "generic release script still contains CopyShare-specific values"
}
if ($scriptSource -match 'gh.*run.*watch') {
  throw "script must use structured workflow polling"
}

Assert-Match $skill '^---[\s\S]*name: project-release-automator' "skill name is not project-release-automator"
Assert-Match $skill '\.codex-release\.json' "skill does not document repository config"
Assert-Match $skill 'Plan[\s\S]*Prepare[\s\S]*Publish' "missing phase order"
Assert-Match $skill '`--force`' "missing force-push guard"
Assert-Match $skill '`git add \.`' "missing staging guard"
Assert-Match $skill 'Detect[\s\S]*Generate[\s\S]*Validate' "skill does not document project setup modes"
Assert-Match $referenceSource 'publish-draft' "config reference missing draft strategy"
Assert-Match $referenceSource 'uploadAssets' "config reference missing upload assets"

$setupSource = Get-Content -Raw -Encoding UTF8 $setupScript
Assert-Match $setupSource 'Refusing to overwrite human-managed workflow' "setup script lacks workflow overwrite protection"
Assert-Match $setupSource 'tauri[\s\S]*node[\s\S]*go' "setup script does not support all project types"
if ($setupSource -match 'D:\\QiLin|CopyShare|suzeccc') {
  throw "generic setup script contains project-specific values"
}
foreach ($template in $workflowTemplates) {
  $templateSource = Get-Content -Raw -Encoding UTF8 $template
  Assert-Match $templateSource '^# Generated by Project Release Automator' "workflow template lacks managed marker"
  Assert-Match $templateSource 'permissions:[\s\S]*contents: write' "workflow template lacks release permissions"
  Assert-Match $templateSource 'draft|releaseDraft' "workflow template does not create a draft release"
}

Write-Host "project-release-automator contract passed"
