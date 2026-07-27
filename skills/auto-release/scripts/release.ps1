[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [ValidateSet("LocalBuild", "Plan", "Prepare", "Publish")]
  [string]$Mode,

  [ValidatePattern('^v?\d+\.\d+\.\d+$')]
  [string]$Version,

  [string]$Summary,

  [ValidateSet("Auto", "Chinese", "English")]
  [string]$PromptLanguage = "Chinese",

  [string]$ReleaseNotes,

  [string]$RepositoryRoot = (Get-Location).Path,

  [string]$ConfigPath = ".codex-release.json",

  [switch]$SkipBuild,

  [switch]$AllowExistingHead,

  [string]$ArtifactManifestPath,

  [string[]]$ManagedLocalArtifactPath = @(),

  [switch]$CanonicalLocalOutput
)

$ErrorActionPreference = "Stop"
$normalizedVersion = if ($Version) { $Version.TrimStart("v") } else { $null }
$script:GitHubCli = $null
$script:Config = $null
$script:ResolvedRepositoryRoot = $null
$script:ConfigFile = $null
$script:Tag = $null
$script:CommitStyleAnalysis = $null
$script:CommitLanguageAnalysis = $null
$script:GitHubRepository = $null
$script:GitHubHost = $null
$utilsScript = Join-Path $PSScriptRoot "release-utils.ps1"

if (-not (Test-Path -LiteralPath $utilsScript)) {
  throw "Release utilities missing: $utilsScript"
}
. $utilsScript
$githubScript = Join-Path $PSScriptRoot "release-github.ps1"
if (-not (Test-Path -LiteralPath $githubScript -PathType Leaf)) { throw "GitHub release module missing: $githubScript" }
. $githubScript
$releaseBuildScript = Join-Path $PSScriptRoot "release-build.ps1"
if (-not (Test-Path -LiteralPath $releaseBuildScript -PathType Leaf)) { throw "Release build module missing: $releaseBuildScript" }
. $releaseBuildScript

if ($Mode -ne "LocalBuild" -and -not $Version) {
  throw "Version is required for $Mode"
}
if ($Mode -ne "LocalBuild" -and [string]::IsNullOrWhiteSpace($Summary)) {
  throw "Summary is required for $Mode"
}
if ($Summary -and $Summary -match "[`r`n]") {
  throw "Summary must be one line"
}
if ($SkipBuild -and $Mode -ne "Prepare") {
  throw "SkipBuild is only valid for Prepare"
}
if ($AllowExistingHead -and $Mode -ne "Publish") {
  throw "AllowExistingHead is only valid for Publish"
}
if ($ArtifactManifestPath -and $Mode -notin @("LocalBuild", "Prepare")) {
  throw "ArtifactManifestPath is only valid for LocalBuild or Prepare"
}
if ($ManagedLocalArtifactPath.Count -gt 0 -and $Mode -ne "LocalBuild") {
  throw "ManagedLocalArtifactPath is only valid for LocalBuild"
}
if ($CanonicalLocalOutput -and $Mode -ne "Prepare") {
  throw "CanonicalLocalOutput is only valid for Prepare"
}

function Invoke-Checked([string]$FilePath, [string[]]$Arguments) {
  & $FilePath @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "$FilePath failed with exit code $LASTEXITCODE"
  }
}

function Invoke-Captured([string]$FilePath, [string[]]$Arguments) {
  $output = & $FilePath @Arguments 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "$FilePath $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)"
  }
  return (($output | Out-String).Trim())
}

function Get-OptionalProperty($Object, [string]$Name, $Default = $null) {
  if ($null -eq $Object) {
    return $Default
  }
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property) {
    return $Default
  }
  return $property.Value
}

function Get-RequiredProperty($Object, [string]$Name, [string]$Context) {
  $value = Get-OptionalProperty $Object $Name
  if ($null -eq $value -or ($value -is [string] -and [string]::IsNullOrWhiteSpace($value))) {
    throw "Missing required config field: $Context.$Name"
  }
  return $value
}

function Get-NormalizedPath([string]$Path) {
  return [IO.Path]::GetFullPath($Path).TrimEnd(
    [IO.Path]::DirectorySeparatorChar,
    [IO.Path]::AltDirectorySeparatorChar
  )
}

function Assert-PathInsideRepository([string]$Path) {
  $fullPath = Get-NormalizedPath $Path
  $root = $script:ResolvedRepositoryRoot
  $rootPrefix = $root + [IO.Path]::DirectorySeparatorChar
  if (
    -not $fullPath.Equals($root, [StringComparison]::OrdinalIgnoreCase) -and
    -not $fullPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)
  ) {
    throw "Configured path escapes repository root: $Path"
  }
  return $fullPath
}

function Resolve-RepositoryPath([string]$Path) {
  if ([IO.Path]::IsPathRooted($Path)) {
    throw "Configured path must be relative: $Path"
  }
  return Assert-PathInsideRepository (Join-Path $script:ResolvedRepositoryRoot $Path)
}

function Write-Utf8NoBom([string]$Path, [string]$Content) {
  [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
}

function Expand-ConfigTokens([string]$Value) {
  if ($null -eq $Value) {
    return $null
  }
  return $Value.
    Replace("{projectName}", [string]$script:Config.projectName).
    Replace("{version}", $normalizedVersion).
    Replace("{tag}", $script:Tag)
}

function Initialize-ReleaseContext {
  if (-not (Test-Path -LiteralPath $RepositoryRoot -PathType Container)) {
    throw "Repository root not found: $RepositoryRoot"
  }

  $script:ResolvedRepositoryRoot = Get-NormalizedPath (Resolve-Path -LiteralPath $RepositoryRoot).Path
  $candidateConfig = if ([IO.Path]::IsPathRooted($ConfigPath)) {
    $ConfigPath
  }
  else {
    Join-Path $script:ResolvedRepositoryRoot $ConfigPath
  }
  if (-not (Test-Path -LiteralPath $candidateConfig -PathType Leaf)) {
    throw "Release config not found: $candidateConfig"
  }
  $script:ConfigFile = Assert-PathInsideRepository (Resolve-Path -LiteralPath $candidateConfig).Path
  $script:Config = Get-Content -Raw -Encoding UTF8 $script:ConfigFile | ConvertFrom-Json
  Assert-ReleaseConfig
  if ($Mode -eq "LocalBuild" -and -not $normalizedVersion) {
    $script:normalizedVersion = Get-CurrentVersion
  }
  $tagPrefix = [string](Get-OptionalProperty $script:Config "tagPrefix" "v")
  $script:Tag = "$tagPrefix$normalizedVersion"
}

function Assert-ReleaseConfig {
  $schemaVersion = [int](Get-RequiredProperty $script:Config "schemaVersion" "root")
  if ($schemaVersion -notin @(1, 2)) {
    throw "Unsupported release config schemaVersion"
  }
  foreach ($name in @("projectName", "branch", "remote")) {
    Get-RequiredProperty $script:Config $name "root" | Out-Null
  }
  $configuredGitHubRepository = [string](Get-OptionalProperty $script:Config "githubRepository" "")
  if ($configuredGitHubRepository -and $configuredGitHubRepository -notmatch '^(?:[^/\s]+/)?[^/\s]+/[^/\s]+$') {
    throw "githubRepository must use OWNER/REPO or HOST/OWNER/REPO"
  }

  $versionConfig = Get-RequiredProperty $script:Config "version" "root"
  $readConfig = Get-RequiredProperty $versionConfig "read" "version"
  Get-RequiredProperty $readConfig "path" "version.read" | Out-Null
  $readPattern = [string](Get-RequiredProperty $readConfig "pattern" "version.read")
  $readRegex = [regex]::new($readPattern)
  if ($readRegex.GetGroupNames() -notcontains "version") {
    throw "version.read.pattern must contain a named 'version' capture group"
  }

  foreach ($update in @(Get-OptionalProperty $versionConfig "updates" @())) {
    Get-RequiredProperty $update "path" "version.updates[]" | Out-Null
    Get-RequiredProperty $update "pattern" "version.updates[]" | Out-Null
    Get-RequiredProperty $update "replacement" "version.updates[]" | Out-Null
    $expectedMatches = [int](Get-OptionalProperty $update "expectedMatches" 1)
    if ($expectedMatches -lt 1) {
      throw "version.updates[].expectedMatches must be positive"
    }
  }

  $commitConfig = Get-OptionalProperty $script:Config "commit"
  if ($commitConfig) {
    $commitPolicy = [string](Get-OptionalProperty $commitConfig "policy" "auto")
    if ($commitPolicy -notin @("auto", "conventional", "off")) {
      throw "commit.policy must be auto, conventional, or off"
    }
    $analyzeCount = [int](Get-OptionalProperty $commitConfig "analyzeCount" 30)
    $minimumSamples = [int](Get-OptionalProperty $commitConfig "minimumSamples" 3)
    $confidenceThreshold = [double](Get-OptionalProperty $commitConfig "confidenceThreshold" 0.6)
    $fallback = [string](Get-OptionalProperty $commitConfig "fallback" "conventional")
    if ($analyzeCount -lt 1) { throw "commit.analyzeCount must be positive" }
    if ($minimumSamples -lt 1 -or $minimumSamples -gt $analyzeCount) {
      throw "commit.minimumSamples must be positive and not exceed commit.analyzeCount"
    }
    if ($confidenceThreshold -le 0 -or $confidenceThreshold -gt 1) {
      throw "commit.confidenceThreshold must be greater than 0 and at most 1"
    }
    if ($fallback -ne "conventional") { throw "commit.fallback must be conventional" }
  }

  $prepare = Get-RequiredProperty $script:Config "prepare" "root"
  $localOutputDirectory = [string](Get-OptionalProperty $prepare "localOutputDirectory" "output")
  if ([string]::IsNullOrWhiteSpace($localOutputDirectory) -or $localOutputDirectory -match '\{(?:version|tag)\}') {
    throw "prepare.localOutputDirectory must be a stable path without version or tag tokens"
  }
  Resolve-RepositoryPath $localOutputDirectory | Out-Null
  foreach ($commandProperty in @("bootstrapCommands", "localCommands", "commands")) {
    foreach ($command in @(Get-OptionalProperty $prepare $commandProperty @())) {
      Get-RequiredProperty $command "name" "prepare.$commandProperty[]" | Out-Null
      Get-RequiredProperty $command "command" "prepare.$commandProperty[]" | Out-Null
    }
  }
  foreach ($inputPath in @(Get-OptionalProperty $prepare "bootstrapInputs" @())) {
    if ([string]::IsNullOrWhiteSpace([string]$inputPath)) {
      throw "prepare.bootstrapInputs[] must be a repository-relative path"
    }
    Resolve-RepositoryPath ([string]$inputPath) | Out-Null
  }
  foreach ($requiredPath in @(Get-OptionalProperty $prepare "bootstrapRequiredPaths" @())) {
    if ([string]::IsNullOrWhiteSpace([string]$requiredPath)) {
      throw "prepare.bootstrapRequiredPaths[] must be a repository-relative path"
    }
    Resolve-RepositoryPath ([string]$requiredPath) | Out-Null
  }
  foreach ($artifactProperty in @("localArtifacts", "artifacts")) {
    foreach ($artifact in @(Get-OptionalProperty $prepare $artifactProperty @())) {
      Get-RequiredProperty $artifact "source" "prepare.$artifactProperty[]" | Out-Null
    }
  }
  foreach ($searchRoot in @(Get-OptionalProperty $prepare "localSearchRoots" @())) {
    if ([string]::IsNullOrWhiteSpace([string]$searchRoot)) {
      throw "prepare.localSearchRoots[] must be a repository-relative path"
    }
    Resolve-RepositoryPath ([string]$searchRoot) | Out-Null
  }

  $publish = Get-RequiredProperty $script:Config "publish" "root"
  $release = Get-RequiredProperty $publish "release" "publish"
  $releaseMode = [string](Get-RequiredProperty $release "mode" "publish.release")
  if ($releaseMode -notin @("publish-draft", "create", "none")) {
    throw "publish.release.mode must be publish-draft, create, or none"
  }
}

function Assert-ConfiguredCommitSummary {
  $commitConfig = Get-OptionalProperty $script:Config "commit"
  $script:CommitStyleAnalysis = Get-RepositoryCommitStyleAnalysis `
    -RepositoryRoot $script:ResolvedRepositoryRoot `
    -CommitConfig $commitConfig
  $script:CommitLanguageAnalysis = Get-RepositoryCommitLanguageAnalysis `
    -RepositoryRoot $script:ResolvedRepositoryRoot `
    -PromptLanguage $PromptLanguage `
    -CommitConfig $commitConfig
  Assert-CommitSummaryStyle -Summary $Summary -Analysis $script:CommitStyleAnalysis
  Assert-CommitSummaryLanguage -Summary $Summary -Analysis $script:CommitLanguageAnalysis
}

function Assert-RepositoryRoot {
  $gitRoot = Invoke-Captured "git" @("rev-parse", "--show-toplevel")
  $normalizedGitRoot = Get-NormalizedPath $gitRoot
  if (-not $normalizedGitRoot.Equals($script:ResolvedRepositoryRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Repository root mismatch: $gitRoot"
  }
}

function Assert-Repository {
  Assert-RepositoryRoot
  $branch = Invoke-Captured "git" @("branch", "--show-current")
  if ($branch -ne [string]$script:Config.branch) {
    throw "Release requires branch $($script:Config.branch); current branch is $branch"
  }

  $remote = [string]$script:Config.remote
  $remoteUrl = Invoke-Captured "git" @("remote", "get-url", $remote)
  $remotePattern = Get-OptionalProperty $script:Config "remoteUrlPattern"
  if ($remotePattern -and $remoteUrl -notmatch [string]$remotePattern) {
    throw "Unexpected $remote remote: $remoteUrl"
  }
}

function Assert-VersionNotLower([string]$Current, [string]$Requested) {
  if ([version]$Requested -lt [version]$Current) {
    throw "Requested version $Requested is lower than current version $Current"
  }
}

function Get-CurrentVersion {
  $readConfig = $script:Config.version.read
  $path = Resolve-RepositoryPath ([string]$readConfig.path)
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw "Version source not found: $path"
  }
  $content = [IO.File]::ReadAllText($path)
  $match = [regex]::Match($content, [string]$readConfig.pattern)
  if (-not $match.Success -or -not $match.Groups["version"].Success) {
    throw "Version pattern not found in $($readConfig.path)"
  }
  $value = $match.Groups["version"].Value
  if ($value -notmatch '^\d+\.\d+\.\d+$') {
    throw "Project version is not a supported semantic version: $value"
  }
  return $value
}

function Get-VersionFilePaths {
  return @(
    @(Get-OptionalProperty $script:Config.version "updates" @()) |
      ForEach-Object { [string]$_.path } |
      Sort-Object -Unique
  )
}

function Backup-VersionFiles {
  $backup = @{}
  foreach ($path in Get-VersionFilePaths) {
    $fullPath = Resolve-RepositoryPath $path
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
      throw "Version file not found: $path"
    }
    $backup[$path] = [IO.File]::ReadAllBytes($fullPath)
  }
  return $backup
}

function Restore-VersionFiles([hashtable]$Backup) {
  foreach ($entry in $Backup.GetEnumerator()) {
    [IO.File]::WriteAllBytes(
      (Resolve-RepositoryPath ([string]$entry.Key)),
      [byte[]]$entry.Value
    )
  }
}

function Update-VersionFiles {
  foreach ($update in @(Get-OptionalProperty $script:Config.version "updates" @())) {
    $path = Resolve-RepositoryPath ([string]$update.path)
    $content = [IO.File]::ReadAllText($path)
    $regex = [regex]::new([string]$update.pattern)
    $expectedMatches = [int](Get-OptionalProperty $update "expectedMatches" 1)
    $actualMatches = $regex.Matches($content).Count
    if ($actualMatches -ne $expectedMatches) {
      throw "Version pattern in $($update.path) matched $actualMatches times; expected $expectedMatches"
    }
    $replacement = Expand-ConfigTokens ([string]$update.replacement)
    Write-Utf8NoBom $path ($regex.Replace($content, $replacement))
  }
}

function Invoke-Plan {
  Assert-Repository
  $currentVersion = Get-CurrentVersion
  Assert-VersionNotLower $currentVersion $normalizedVersion
  $releaseMode = [string]$script:Config.publish.release.mode

  @(
    "Project: $($script:Config.projectName)",
    "Repository: $($script:ResolvedRepositoryRoot)",
    "Config: $($script:ConfigFile)",
    "Current version: $currentVersion",
    "Target version: $normalizedVersion",
    "Tag: $($script:Tag)",
    "Commit style: $($script:CommitStyleAnalysis.selectedStyle) ($($script:CommitStyleAnalysis.reason))",
    "Commit language: $($script:CommitLanguageAnalysis.selectedLanguage) ($($script:CommitLanguageAnalysis.reason))",
    "Branch push: $($script:Config.remote)/$($script:Config.branch)",
    "Prepare parallel: $([bool](Get-OptionalProperty $script:Config.prepare 'parallel' $false))"
  )
  foreach ($command in @(Get-OptionalProperty $script:Config.prepare "commands" @())) {
    "Prepare command: $(Expand-ConfigTokens ([string]$command.name)) -> $(Expand-ConfigTokens ([string]$command.command))"
  }
  foreach ($artifact in @(Get-OptionalProperty $script:Config.prepare "artifacts" @())) {
    $source = Expand-ConfigTokens ([string]$artifact.source)
    $destination = Expand-ConfigTokens ([string](Get-OptionalProperty $artifact "destination" $artifact.source))
    "Artifact: $source -> $destination"
  }
  $workflow = Get-OptionalProperty $script:Config.publish "workflow"
  if ($workflow) {
    "Workflow: $($workflow.name) via gh run view --json"
  }
  "Release mode: $releaseMode"
  "Push: git push --atomic $($script:Config.remote) $($script:Config.branch) $($script:Tag)"
}

function Invoke-Prepare {
  Assert-Repository
  Update-RemoteBranch
  Assert-RemoteIsAncestor
  $prepareHead = Invoke-Captured "git" @("rev-parse", "HEAD")
  Get-TagState -Tag $script:Tag -HeadSha $prepareHead | Out-Null

  $currentVersion = Get-CurrentVersion
  Assert-VersionNotLower $currentVersion $normalizedVersion
  $backup = Backup-VersionFiles

  try {
    if ([version]$normalizedVersion -gt [version]$currentVersion) {
      Update-VersionFiles
    }
    if ((Get-CurrentVersion) -ne $normalizedVersion) {
      throw "Project version does not match requested version after update"
    }

    $artifacts = @()
    if ($SkipBuild) {
      Write-Host "Local build is current; skipping configured build commands"
    }
    else {
      if ($CanonicalLocalOutput) { Stop-LocalBuildProcesses }
      Invoke-ConfiguredCommands
      $artifacts = @(Get-PreparedArtifacts ([bool]$CanonicalLocalOutput))
      Write-ArtifactManifest $artifacts
    }
    Write-Host "Prepared $($script:Config.projectName) $($script:Tag)"
    if ($artifacts.Count -gt 0) {
      $artifacts | Format-List
    }
  }
  catch {
    Restore-VersionFiles $backup
    throw
  }
}

function Invoke-LocalBuild {
  Assert-RepositoryRoot
  $currentVersion = Get-CurrentVersion
  Write-Host "Local build: $($script:Config.projectName) $currentVersion"
  Stop-LocalBuildProcesses
  Invoke-ConfiguredCommands $true
  $artifacts = @(Get-PreparedArtifacts $true)
  Write-ArtifactManifest $artifacts
  Write-Host "Local build completed without changing the project version"
  if ($artifacts.Count -gt 0) {
    $artifacts | Format-List
  }
}

function Invoke-Publish {
  Assert-Repository
  $releaseConfig = $script:Config.publish.release
  $releaseMode = [string]$releaseConfig.mode
  if ($releaseMode -ne "none") {
    $notesConfig = Get-OptionalProperty $script:Config "releaseNotes"
    $defaultHeading =
      "## " +
      ([char]0x66F4).ToString() +
      ([char]0x65B0).ToString() +
      ([char]0x5185).ToString() +
      ([char]0x5BB9).ToString()
    $heading = [string](Get-OptionalProperty $notesConfig "heading" $defaultHeading)
    $minItems = [int](Get-OptionalProperty $notesConfig "minItems" 2)
    $maxItems = [int](Get-OptionalProperty $notesConfig "maxItems" 6)
    $requireChinese = [bool](Get-OptionalProperty $notesConfig "requireChinese" $false)
    Assert-ReleaseNotes `
      -ReleaseNotes $ReleaseNotes `
      -Heading $heading `
      -MinItems $minItems `
      -MaxItems $maxItems `
      -RequireChinese $requireChinese
  }

  Update-RemoteBranch
  Assert-RemoteIsAncestor

  $currentVersion = Get-CurrentVersion
  if ($currentVersion -ne $normalizedVersion) {
    throw "Project version $currentVersion does not match requested version $normalizedVersion"
  }

  $status = Invoke-Captured "git" @("status", "--porcelain")
  if ($status) {
    throw "Working tree must be clean before Publish"
  }

  $headSubject = Invoke-Captured "git" @("log", "-1", "--pretty=%s")
  if ($headSubject -ne $Summary) {
    throw "HEAD subject does not match the release summary"
  }

  $workflow = Get-OptionalProperty $script:Config.publish "workflow"
  $needsGitHub = $workflow -or $releaseMode -ne "none"
  if ($needsGitHub) {
    Disable-StaleLoopbackProxy
    Assert-GitHubAuth
  }

  $headSha = Invoke-Captured "git" @("rev-parse", "HEAD")
  $tagState = Get-TagState -Tag $script:Tag -HeadSha $headSha
  if (-not $tagState.LocalExists -and $tagState.RemoteExists) {
    Invoke-Checked "git" @(
      "fetch", "--no-tags", [string]$script:Config.remote,
      "refs/tags/$($script:Tag):refs/tags/$($script:Tag)"
    )
    $tagState = Get-TagState -Tag $script:Tag -HeadSha $headSha
  }
  $createdLocalTag = $false
  if (-not $tagState.LocalExists) {
    Invoke-Checked "git" @("tag", "-a", $script:Tag, "-m", $Summary)
    $createdLocalTag = $true
  }

  try {
    if ($tagState.RemoteExists) {
      Invoke-Checked "git" @("push", [string]$script:Config.remote, [string]$script:Config.branch)
      Write-Host "Release tag already exists on current HEAD; resuming $($script:Tag)"
    }
    else {
      Invoke-Checked "git" @(
        "push",
        "--atomic",
        [string]$script:Config.remote,
        [string]$script:Config.branch,
        $script:Tag
      )
    }
  }
  catch {
    $remoteTag = ""
    try {
      $remoteTag = Get-RemoteTagTarget $script:Tag
    }
    catch {
      Write-Warning "Could not verify remote tag state after push failure"
    }
    if ($createdLocalTag -and -not $remoteTag) {
      & git tag -d $script:Tag | Out-Null
    }
    throw
  }

  if ($workflow) {
    $run = Find-WorkflowRun -Workflow $workflow -HeadSha $headSha
    Write-Host "Workflow: $($run.url)"
    Wait-WorkflowRun -Workflow $workflow -RunId ([long]$run.databaseId) | Out-Null
  }

  Invoke-ReleasePublication -ReleaseNotes $ReleaseNotes
}

$previousLocation = Get-Location
try {
  Initialize-ReleaseContext
  Set-Location -LiteralPath $script:ResolvedRepositoryRoot
  if ($Mode -in @("Plan", "Publish")) {
    Assert-ConfiguredCommitSummary
  }
  if ($Mode -eq "LocalBuild") {
    Invoke-LocalBuild
  }
  elseif ($Mode -eq "Plan") {
    Invoke-Plan
  }
  elseif ($Mode -eq "Prepare") {
    Invoke-Prepare
  }
  else {
    Invoke-Publish
  }
}
finally {
  Set-Location -LiteralPath $previousLocation
}
