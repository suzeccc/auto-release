[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [ValidateSet("LocalBuild", "Ignore", "CommitPush", "Release")]
  [string]$Operation,

  [ValidatePattern('^v?\d+\.\d+\.\d+$')]
  [string]$Version,

  [string]$Summary,

  [ValidateSet("Auto", "Chinese", "English")]
  [string]$PromptLanguage = "Chinese",

  [string]$ReleaseNotes,

  [string]$RepositoryRoot = (Get-Location).Path,

  [string]$ConfigPath = ".codex-release.json",

  [ValidateSet("auto", "tauri", "node", "go", "python", "rust", "dotnet", "java", "cmake", "flutter", "android", "electron", "docker")]
  [string]$ProjectType = "auto",

  [ValidateSet("Stop", "CreateSeparate", "ReuseCompatible")]
  [string]$WorkflowPolicy = "Stop",

  [string]$WorkflowPath = ".github/workflows/release.yml",

  [string]$SeparateWorkflowPath = ".github/workflows/auto-release.yml",

  [switch]$ForceRebuild,

  [switch]$WhatIf,

  [ValidateSet("Single", "AutoSplit")]
  [string]$CommitStrategy = "Single",

  [string]$CommitPlanPath,

  [ValidateRange(2, 8)]
  [int]$MaxCommits = 4,

  [ValidateSet("Audit", "Apply", "ApplyAndUntrack")]
  [string]$IgnoreMode = "Audit",

  [string]$IgnorePlanPath,

  [ValidateSet("Human", "Json")]
  [string]$OutputFormat = "Human"
)

$ErrorActionPreference = "Stop"
$script:ResolvedRepositoryRoot = $null
$script:Utf8NoBom = [Text.UTF8Encoding]::new($false)
$script:Stage = "Initialize"
$script:CommitLanguageAnalysis = $null
$setupScript = Join-Path $PSScriptRoot "setup-project.ps1"
$releaseScript = Join-Path $PSScriptRoot "release.ps1"
$ignoreScript = Join-Path $PSScriptRoot "ignore-audit.ps1"
$utilsScript = Join-Path $PSScriptRoot "release-utils.ps1"

if (-not (Test-Path -LiteralPath $utilsScript -PathType Leaf)) {
  throw "Release utilities missing: $utilsScript"
}
. $utilsScript
$commitTransactionScript = Join-Path $PSScriptRoot "commit-transaction.ps1"
if (-not (Test-Path -LiteralPath $commitTransactionScript -PathType Leaf)) { throw "Commit transaction module missing: $commitTransactionScript" }
. $commitTransactionScript
$localBuildStateScript = Join-Path $PSScriptRoot "local-build-state.ps1"
if (-not (Test-Path -LiteralPath $localBuildStateScript -PathType Leaf)) { throw "Local build state module missing: $localBuildStateScript" }
. $localBuildStateScript

if ($OutputFormat -eq "Json") {
  $InformationPreference = "SilentlyContinue"
}

function Get-OptionalProperty($Object, [string]$Name, $Default = $null) {
  if ($null -eq $Object) { return $Default }
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property) { return $Default }
  return $property.Value
}

function Get-NormalizedPath([string]$Path) {
  return [IO.Path]::GetFullPath($Path).TrimEnd(
    [IO.Path]::DirectorySeparatorChar,
    [IO.Path]::AltDirectorySeparatorChar
  )
}

function Invoke-GitCaptured([string[]]$Arguments) {
  $previousPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $output = & git -C $script:ResolvedRepositoryRoot @Arguments 2>&1
    $exitCode = $LASTEXITCODE
  }
  finally {
    $ErrorActionPreference = $previousPreference
  }
  if ($exitCode -ne 0) {
    throw "git $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)"
  }
  $standardOutput = @($output | Where-Object { $_ -isnot [Management.Automation.ErrorRecord] })
  return (($standardOutput | Out-String).Trim())
}

function Invoke-GitChecked([string[]]$Arguments) {
  $previousPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $output = & git -C $script:ResolvedRepositoryRoot @Arguments 2>&1
    $exitCode = $LASTEXITCODE
  }
  finally {
    $ErrorActionPreference = $previousPreference
  }
  if ($exitCode -ne 0) {
    throw "git $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)"
  }
  foreach ($line in @($output)) { Write-Host $line }
}

function Write-OperationResult($Result) {
  if ($OutputFormat -eq "Json") {
    [Console]::Out.WriteLine(($Result | ConvertTo-Json -Depth 20 -Compress))
  }
}

function Write-Preview($Preview) {
  if ($OutputFormat -eq "Json") {
    Write-OperationResult $Preview
    return
  }
  Write-Host "WhatIf: $($Preview.operation)"
  Write-Host "Repository: $($Preview.repositoryRoot)"
  if ($Preview.projectType) { Write-Host "Project type: $($Preview.projectType)" }
  if ($null -ne $Preview.localBuildFresh) { Write-Host "Reusable local build: $($Preview.localBuildFresh)" }
  if ($Preview.branch) { Write-Host "Branch: $($Preview.remote)/$($Preview.branch)" }
  if ($Preview.commitStyle) {
    Write-Host "Commit format: $($Preview.commitStyle.selectedStyle) ($($Preview.commitStyle.reason))"
  }
  if ($Preview.commitLanguage) {
    Write-Host "Commit language: $($Preview.commitLanguage.selectedLanguage) ($($Preview.commitLanguage.reason))"
  }
  foreach ($group in @($Preview.commitPlan.groups)) {
    Write-Host "Commit: $($group.summary)"
    foreach ($path in @($group.paths)) { Write-Host "  - $path" }
  }
  foreach ($action in @($Preview.actions)) { Write-Host "Would: $action" }
}

function Assert-RepositoryContext {
  if (-not (Test-Path -LiteralPath $RepositoryRoot -PathType Container)) {
    throw "Repository root not found: $RepositoryRoot"
  }
  $script:ResolvedRepositoryRoot = Get-NormalizedPath (Resolve-Path -LiteralPath $RepositoryRoot).Path
  $gitRoot = Get-NormalizedPath (Invoke-GitCaptured @("rev-parse", "--show-toplevel"))
  if (-not $gitRoot.Equals($script:ResolvedRepositoryRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Repository root mismatch: $gitRoot"
  }
}

function Resolve-RepositoryPath([string]$RelativePath) {
  if ([IO.Path]::IsPathRooted($RelativePath)) { throw "Path must be repository-relative: $RelativePath" }
  $fullPath = Get-NormalizedPath (Join-Path $script:ResolvedRepositoryRoot $RelativePath)
  $prefix = $script:ResolvedRepositoryRoot + [IO.Path]::DirectorySeparatorChar
  if (-not $fullPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Path escapes repository root: $RelativePath"
  }
  return $fullPath
}

function Read-ReleaseConfig {
  $path = Resolve-RepositoryPath $ConfigPath
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
  try { return Get-Content -Raw -Encoding UTF8 -LiteralPath $path | ConvertFrom-Json }
  catch { throw "Release config is invalid JSON: $path" }
}

function Get-ConfigRelativePath {
  $fullPath = Resolve-RepositoryPath $ConfigPath
  $prefix = $script:ResolvedRepositoryRoot + [IO.Path]::DirectorySeparatorChar
  return $fullPath.Substring($prefix.Length).Replace("\", "/")
}

function Test-GitPathTracked([string]$RelativePath) {
  $previousPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    & git -C $script:ResolvedRepositoryRoot ls-files --error-unmatch -- $RelativePath 2>$null | Out-Null
    $exitCode = $LASTEXITCODE
  }
  finally {
    $ErrorActionPreference = $previousPreference
  }
  return $exitCode -eq 0
}

function Test-GitPathIgnored([string]$RelativePath) {
  $previousPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    & git -C $script:ResolvedRepositoryRoot check-ignore -q --no-index -- $RelativePath 2>$null
    $exitCode = $LASTEXITCODE
  }
  finally {
    $ErrorActionPreference = $previousPreference
  }
  return $exitCode -eq 0
}

function Assert-LocalConfigReadyForCommit {
  $configFile = Resolve-RepositoryPath $ConfigPath
  if (-not (Test-Path -LiteralPath $configFile -PathType Leaf)) { return }
  $relativePath = Get-ConfigRelativePath
  if (-not (Test-GitPathIgnored $relativePath)) {
    throw "Local release config must be ignored before commit: $relativePath. Run Ignore ApplyAndUntrack."
  }
  if (Test-GitPathTracked $relativePath) {
    throw "Local release config is still tracked: $relativePath. Run Ignore ApplyAndUntrack."
  }
}

function Get-ConfiguredCommitStyleAnalysis($Config) {
  $commitConfig = Get-OptionalProperty $Config "commit"
  return Get-RepositoryCommitStyleAnalysis `
    -RepositoryRoot $script:ResolvedRepositoryRoot `
    -CommitConfig $commitConfig
}

function Get-ConfiguredCommitLanguageAnalysis($Config) {
  $commitConfig = Get-OptionalProperty $Config "commit"
  return Get-RepositoryCommitLanguageAnalysis `
    -RepositoryRoot $script:ResolvedRepositoryRoot `
    -PromptLanguage $PromptLanguage `
    -CommitConfig $commitConfig
}

function Assert-ConfiguredCommitSummary($Config) {
  $analysis = Get-ConfiguredCommitStyleAnalysis $Config
  $script:CommitLanguageAnalysis = Get-ConfiguredCommitLanguageAnalysis $Config
  Assert-CommitSummaryStyle -Summary $Summary -Analysis $analysis
  Assert-CommitSummaryLanguage -Summary $Summary -Analysis $script:CommitLanguageAnalysis
  return $analysis
}

function Disable-StaleLoopbackProxy {
  $proxyValue = @($env:HTTPS_PROXY, $env:HTTP_PROXY, $env:ALL_PROXY) | Where-Object { $_ } | Select-Object -First 1
  if (-not $proxyValue) { return }
  try { $proxyUri = [Uri]$proxyValue } catch { return }
  if ($proxyUri.Host -notin @("127.0.0.1", "localhost", "::1")) { return }
  $client = New-Object Net.Sockets.TcpClient
  try { $reachable = $client.ConnectAsync($proxyUri.Host, $proxyUri.Port).Wait(750) -and $client.Connected }
  catch { $reachable = $false }
  finally { $client.Dispose() }
  if (-not $reachable) {
    Write-Warning "Ignoring stale loopback proxy $proxyValue"
    $env:HTTP_PROXY = $null
    $env:HTTPS_PROXY = $null
    $env:ALL_PROXY = $null
  }
}

function Get-BranchAndRemote($Config, [bool]$UseConfiguredBranch = $true) {
  $branch = if ($UseConfiguredBranch -and $Config) {
    [string]$Config.branch
  }
  else {
    Invoke-GitCaptured @("branch", "--show-current")
  }
  if (-not $branch) { throw "Detached HEAD is not supported" }
  $remote = if ($Config) { [string]$Config.remote } else { "origin" }
  if (-not $remote) { $remote = "origin" }
  return [pscustomobject]@{ Branch = $branch; Remote = $remote }
}

function Assert-RemoteReady($Config, [bool]$UseConfiguredBranch = $true) {
  $target = Get-BranchAndRemote $Config $UseConfiguredBranch
  Invoke-GitCaptured @("remote", "get-url", $target.Remote) | Out-Null
  Disable-StaleLoopbackProxy
  $remoteHead = Invoke-GitCaptured @("ls-remote", "--heads", $target.Remote, "refs/heads/$($target.Branch)")
  if ($remoteHead) {
    Invoke-GitChecked @(
      "fetch", "--no-tags", $target.Remote,
      "refs/heads/$($target.Branch):refs/remotes/$($target.Remote)/$($target.Branch)"
    )
    & git -C $script:ResolvedRepositoryRoot merge-base --is-ancestor "$($target.Remote)/$($target.Branch)" HEAD
    if ($LASTEXITCODE -ne 0) {
      throw "$($target.Remote)/$($target.Branch) is ahead or diverged; operation stopped"
    }
  }
  return [pscustomobject]@{ Branch = $target.Branch; Remote = $target.Remote; Exists = [bool]$remoteHead }
}

function Get-WorkflowSettings($Config) {
  $automation = Get-OptionalProperty $Config "automation"
  return [pscustomobject]@{
    Managed = [bool](Get-OptionalProperty $automation "managedWorkflow" $false)
    Path = [string](Get-OptionalProperty $automation "workflowFile" $WorkflowPath)
    Generator = [string](Get-OptionalProperty $automation "generator" "")
    ProjectType = [string](Get-OptionalProperty $Config "projectType" $ProjectType)
  }
}

function Ensure-ReleaseAutomation([string]$RequestedOperation) {
  if (-not (Test-Path -LiteralPath $setupScript -PathType Leaf)) { throw "Setup script missing: $setupScript" }
  $config = Read-ReleaseConfig
  if (-not $config) {
    if ($RequestedOperation -eq "LocalBuild") {
      & $setupScript -Mode GenerateLocal -ProjectType $ProjectType -RepositoryRoot $script:ResolvedRepositoryRoot `
        -ConfigPath $ConfigPath -WorkflowPath $WorkflowPath
    }
    else {
      & $setupScript -Mode Generate -ProjectType $ProjectType -RepositoryRoot $script:ResolvedRepositoryRoot `
        -ConfigPath $ConfigPath -WorkflowPath $WorkflowPath `
        -ExistingWorkflowPolicy $WorkflowPolicy -SeparateWorkflowPath $SeparateWorkflowPath
    }
    return Read-ReleaseConfig
  }

  if ($RequestedOperation -eq "LocalBuild") {
    Write-Host "Local build uses repository config without validating GitHub release workflow"
    return $config
  }

  $updateManaged = $RequestedOperation -eq "Release"
  $settings = Get-WorkflowSettings $config
  $automation = Get-OptionalProperty $config "automation"
  $localOnly = [bool](Get-OptionalProperty $automation "localOnly" $false)
  if ($updateManaged -and $localOnly -and $settings.Generator -in @("auto-release", "project-release-automator")) {
    & $setupScript -Mode Generate -ProjectType $settings.ProjectType -RepositoryRoot $script:ResolvedRepositoryRoot `
      -ConfigPath $ConfigPath -WorkflowPath $settings.Path `
      -ExistingWorkflowPolicy $WorkflowPolicy -SeparateWorkflowPath $SeparateWorkflowPath
  }
  elseif ($updateManaged -and $settings.Managed -and $settings.Generator -in @("auto-release", "project-release-automator")) {
    & $setupScript -Mode Generate -ProjectType $settings.ProjectType -RepositoryRoot $script:ResolvedRepositoryRoot `
      -ConfigPath $ConfigPath -WorkflowPath $settings.Path -ExistingWorkflowPolicy Stop
  }
  else {
    & $setupScript -Mode Validate -RepositoryRoot $script:ResolvedRepositoryRoot -ConfigPath $ConfigPath -WorkflowPath $settings.Path
  }
  return Read-ReleaseConfig
}

function Invoke-WhatIfPreview {
  $config = Read-ReleaseConfig
  $detected = $null
  if (-not $config -and $Operation -ne "CommitPush") {
    $detected = (& $setupScript -Mode Detect -ProjectType $ProjectType -RepositoryRoot $script:ResolvedRepositoryRoot) | ConvertFrom-Json
  }
  $projectTypeValue = if ($config) { [string](Get-OptionalProperty $config "projectType" "custom") } else { [string]$detected.projectType }
  $actions = @()
  $branch = ""
  $remote = ""
  $fresh = $null
  $commitAnalysis = $null
  $commitLanguageAnalysis = $null
  if ($Operation -eq "CommitPush") {
    Assert-LocalConfigReadyForCommit
    $commitAnalysis = Get-ConfiguredCommitStyleAnalysis $config
    $commitLanguageAnalysis = Get-ConfiguredCommitLanguageAnalysis $config
    $target = Get-BranchAndRemote $config $false
    $branch = $target.Branch
    $remote = $target.Remote
    if ($CommitStrategy -eq "AutoSplit") {
      $commitPlan = Read-CommitPlan $commitAnalysis $commitLanguageAnalysis
      $actions = @("validate exact commit-plan coverage", "create $(@($commitPlan.groups).Count) commits on a transaction branch", "fast-forward the current branch", "push all commits together")
    }
    else {
      Assert-CommitSummaryStyle -Summary $Summary -Analysis $commitAnalysis
      Assert-CommitSummaryLanguage -Summary $Summary -Analysis $commitLanguageAnalysis
      $actions = @("stage all safe changes", "commit with the supplied prompt-language summary", "push the current branch")
    }
  }
  elseif ($Operation -eq "LocalBuild") {
    $fresh = if ($config) { -not $ForceRebuild -and (Test-LocalBuildFresh $config) } else { $false }
    if ($fresh) {
      $actions = @("reuse the verified local build receipt")
    }
    else {
      $actions = @("initialize local-only configuration if needed", "run dependency bootstrap when its inputs changed", "run fast local commands", "write canonical output and build receipt")
    }
  }
  else {
    if (-not $Version) { throw "Version is required for Release" }
    $commitAnalysis = Assert-ConfiguredCommitSummary $config
    $commitLanguageAnalysis = $script:CommitLanguageAnalysis
    if ([string]::IsNullOrWhiteSpace($ReleaseNotes) -or $ReleaseNotes -notmatch '[\u4e00-\u9fff]') {
      throw "Chinese ReleaseNotes are required for Release"
    }
    if ($config) {
      Assert-LocalConfigReadyForCommit
      $target = Get-BranchAndRemote $config $true
      $branch = $target.Branch
      $remote = $target.Remote
      $fresh = -not $ForceRebuild -and (Test-LocalBuildFresh $config)
    }
    $actions = @("require a clean working tree", "create or validate release automation", "plan version $Version", "run a verified build unless reusable", "commit only release-owned version and managed automation changes", "atomically push branch and tag", "wait for GitHub Actions and publish the draft Release")
  }
  $changesText = Invoke-GitCaptured @("status", "--short")
  return [pscustomobject][ordered]@{
    operation = $Operation
    status = "planned"
    whatIf = $true
    repositoryRoot = $script:ResolvedRepositoryRoot
    projectType = $projectTypeValue
    version = $Version
    branch = $branch
    remote = $remote
    localBuildFresh = $fresh
    commitStyle = $commitAnalysis
    commitLanguage = $commitLanguageAnalysis
    commitStrategy = $CommitStrategy
    commitPlan = $commitPlan
    changes = @($changesText -split "`r?`n" | Where-Object { $_ })
    actions = $actions
  }
}

function Invoke-Main {
  $script:Stage = "RepositoryCheck"
  Assert-RepositoryContext
  if ($Operation -eq "Release") {
    $script:Stage = "ReleasePreflight"
    Assert-ReleaseWorkingTreeClean
  }
  if ($Operation -eq "Ignore") {
    $script:Stage = "Ignore"
    if (-not (Test-Path -LiteralPath $ignoreScript -PathType Leaf)) { throw "Ignore audit script missing: $ignoreScript" }
    $mode = if ($WhatIf) { "Audit" } else { $IgnoreMode }
    $ignoreArguments = @{
      Mode = $mode
      RepositoryRoot = $script:ResolvedRepositoryRoot
      OutputFormat = "Json"
      NoWritePlan = [bool]$WhatIf
    }
    if ($IgnorePlanPath) { $ignoreArguments.PlanPath = $IgnorePlanPath }
    $output = & $ignoreScript @ignoreArguments
    if ($LASTEXITCODE -ne 0) { throw "Ignore $mode failed" }
    $result = (@($output) | Select-Object -Last 1) | ConvertFrom-Json
    if ($OutputFormat -eq "Json") {
      Write-OperationResult $result
    }
    elseif ($mode -eq "Audit") {
      Write-Host "Ignore audit: $script:ResolvedRepositoryRoot"
      foreach ($rule in @($result.plan.rules)) { Write-Host "Add: $($rule.pattern) - $($rule.reason)" }
      foreach ($item in @($result.plan.review)) { Write-Host "Review: $($item.pattern) - $($item.reason)" }
      foreach ($path in @($result.plan.untrackPaths)) { Write-Host "Tracked match: $path" }
      foreach ($record in @($result.plan.trackedButIgnored)) { Write-Host "Tracked but ignored: $($record.path) <- $($record.pattern)" }
      foreach ($path in @($result.plan.sensitivePaths)) { Write-Host "Sensitive: $path" }
      Write-Host "Plan: $($result.planPath)"
    }
    else {
      Write-Host "Ignore $mode completed"
      Write-Host "Rules added: $(@($result.rulesAdded).Count)"
      Write-Host "Paths untracked: $(@($result.untrackedPaths).Count)"
    }
    return
  }
  if ($WhatIf) {
    $script:Stage = "Plan"
    Write-Preview (Invoke-WhatIfPreview)
    return
  }

  if ($Operation -eq "CommitPush") {
    $script:Stage = "CommitPush"
    $commit = if ($CommitStrategy -eq "AutoSplit") {
      Commit-PlannedChanges $true
    }
    else {
      Commit-AllChanges $true "" $false
    }
    Write-OperationResult ([pscustomobject][ordered]@{
      operation = $Operation; status = "succeeded"; committed = $commit.Committed; commitCount = $commit.CommitCount; commits = $commit.Commits; head = $commit.Head; commitStyle = $commit.CommitStyle; commitLanguage = $commit.CommitLanguage
    })
    return
  }

  $script:Stage = "Automation"
  $config = Ensure-ReleaseAutomation $Operation
  $releaseAutomationPaths = if ($Operation -eq "Release") { @(Get-ChangedPaths) } else { @() }

  if ($Operation -eq "LocalBuild") {
    $script:Stage = "LocalBuild"
    if (-not $ForceRebuild -and (Test-LocalBuildFresh $config)) {
      Write-Host "Local build is current; reusing verified output. Use -ForceRebuild to rebuild."
      $receipt = Read-LocalBuildReceipt
      Write-OperationResult ([pscustomobject][ordered]@{
        operation = $Operation; status = "succeeded"; reused = $true; artifacts = @($receipt.artifacts)
      })
      return
    }
    $previousPaths = @(Get-ReceiptArtifactPaths)
    $manifestPath = Get-ArtifactManifestPath
    try {
      if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        Remove-Item -LiteralPath $manifestPath -Force
      }
      & $releaseScript -Mode LocalBuild -RepositoryRoot $script:ResolvedRepositoryRoot -ConfigPath $ConfigPath `
        -ArtifactManifestPath $manifestPath -ManagedLocalArtifactPath $previousPaths | Out-Host
      Write-LocalBuildReceipt $config $manifestPath $previousPaths $true
    }
    finally {
      if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        Remove-Item -LiteralPath $manifestPath -Force
      }
    }
    $receipt = Read-LocalBuildReceipt
    Write-OperationResult ([pscustomobject][ordered]@{
      operation = $Operation; status = "succeeded"; reused = $false; artifacts = @($receipt.artifacts)
    })
    return
  }

  if (-not $Version) { throw "Version is required for Release" }
  $commitAnalysis = Assert-ConfiguredCommitSummary $config
  if ([string]::IsNullOrWhiteSpace($ReleaseNotes) -or $ReleaseNotes -notmatch '[\u4e00-\u9fff]') {
    throw "Chinese ReleaseNotes are required for Release"
  }
  $releaseMode = [string](Get-OptionalProperty $config.publish.release "mode" "none")
  if ($releaseMode -eq "none") { throw "Release operation requires GitHub Release creation" }
  if (-not (Get-OptionalProperty $config.publish "workflow")) { throw "Release operation requires a tag-triggered build workflow" }
  $releaseCommitPaths = @(Get-ReleaseCommitPaths $config $releaseAutomationPaths)

  $localBuildIsFresh = -not $ForceRebuild -and (Test-LocalBuildFresh $config)
  $script:Stage = "Plan"
  & $releaseScript -Mode Plan -Version $Version -Summary $Summary -PromptLanguage $PromptLanguage -RepositoryRoot $script:ResolvedRepositoryRoot -ConfigPath $ConfigPath | Out-Host
  $manifestPath = Get-ArtifactManifestPath
  try {
    $verifiedFingerprint = ""
    $script:Stage = "Prepare"
    if ($localBuildIsFresh) {
      $before = Get-SourceFingerprint $config
      & $releaseScript -Mode Prepare -Version $Version -Summary $Summary `
        -PromptLanguage $PromptLanguage -RepositoryRoot $script:ResolvedRepositoryRoot -ConfigPath $ConfigPath -SkipBuild | Out-Host
      $config = Read-ReleaseConfig
      $after = Get-SourceFingerprint $config
      if ($before -eq $after -and (Test-LocalBuildFresh $config)) {
        $verifiedFingerprint = $after
      }
      else {
        Write-Warning "The verified local build became stale during release preparation; rebuilding"
        $result = Invoke-StableReleaseBuild $config $manifestPath
        $config = $result.Config
        $verifiedFingerprint = $result.Fingerprint
      }
    }
    else {
      $result = Invoke-StableReleaseBuild $config $manifestPath
      $config = $result.Config
      $verifiedFingerprint = $result.Fingerprint
    }
    $script:Stage = "ReleaseCommit"
    $commit = Commit-ReleaseChanges $releaseCommitPaths $verifiedFingerprint
    $script:Stage = "Publish"
    & $releaseScript -Mode Publish -Version $Version -Summary $Summary -ReleaseNotes $ReleaseNotes `
      -PromptLanguage $PromptLanguage -RepositoryRoot $script:ResolvedRepositoryRoot -ConfigPath $ConfigPath -AllowExistingHead:(-not $commit.Committed)
    Write-OperationResult ([pscustomobject][ordered]@{
      operation = $Operation; status = "succeeded"; version = $Version; tag = "$([string](Get-OptionalProperty $config 'tagPrefix' 'v'))$($Version.TrimStart('v'))"; head = $commit.Head; localBuildReused = $localBuildIsFresh; commitStyle = $commitAnalysis; commitLanguage = $commit.CommitLanguage
    })
  }
  finally {
    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
      Remove-Item -LiteralPath $manifestPath -Force
    }
  }
}

try {
  Invoke-Main
}
catch {
  if ($OutputFormat -eq "Json") {
    $code = "AUTO_RELEASE_$($script:Stage.ToUpperInvariant())_FAILED"
    Write-OperationResult ([pscustomobject][ordered]@{
      operation = $Operation
      status = "failed"
      stage = $script:Stage
      errorCode = $code
      message = $_.Exception.Message
    })
    exit 1
  }
  throw
}
