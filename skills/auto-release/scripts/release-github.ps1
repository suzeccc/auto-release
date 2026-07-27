# Internal GitHub repository, workflow, tag, and release asset operations.

function Get-LocalTagTarget([string]$Tag) {
  $target = & git rev-parse -q --verify "$Tag^{commit}" 2>$null
  if ($LASTEXITCODE -ne 0) { return "" }
  return (($target | Out-String).Trim())
}
function Get-RemoteTagTarget([string]$Tag) {
  $output = Invoke-Captured "git" @(
    "ls-remote",
    "--tags",
    [string]$script:Config.remote,
    "refs/tags/$Tag",
    "refs/tags/$Tag^{}"
  )
  if (-not $output) { return "" }
  $records = @($output -split "`r?`n" | Where-Object { $_ })
  $peeled = @($records | Where-Object { $_ -match [regex]::Escape("refs/tags/$Tag^{}") }) | Select-Object -First 1
  $selected = if ($peeled) { $peeled } else { $records | Select-Object -First 1 }
  return ([string]$selected -split "`t", 2)[0]
}

function Get-TagState([string]$Tag, [string]$HeadSha) {
  $localTarget = Get-LocalTagTarget $Tag
  $remoteTarget = Get-RemoteTagTarget $Tag
  if ($localTarget -and $localTarget -ne $HeadSha) {
    throw "Local tag $Tag points to $localTarget instead of current HEAD $HeadSha"
  }
  if ($remoteTarget -and $remoteTarget -ne $HeadSha) {
    throw "Remote tag $Tag points to $remoteTarget instead of current HEAD $HeadSha"
  }
  return [pscustomobject]@{
    LocalExists = [bool]$localTarget
    RemoteExists = [bool]$remoteTarget
    LocalTarget = $localTarget
    RemoteTarget = $remoteTarget
  }
}

function Update-RemoteBranch {
  $remote = [string]$script:Config.remote
  $branch = [string]$script:Config.branch
  Invoke-Checked "git" @(
    "fetch",
    "--no-tags",
    $remote,
    "refs/heads/${branch}:refs/remotes/${remote}/${branch}"
  )
}

function Assert-RemoteIsAncestor {
  $remoteRef = "$($script:Config.remote)/$($script:Config.branch)"
  & git merge-base --is-ancestor $remoteRef HEAD
  if ($LASTEXITCODE -ne 0) {
    throw "$remoteRef is ahead or diverged; release stopped"
  }
}

function Resolve-GitHubCli {
  $command = Get-Command gh -ErrorAction SilentlyContinue
  if ($command) {
    return $command.Source
  }

  $fallback = Join-Path $env:LOCALAPPDATA "Programs\GitHub CLI\bin\gh.exe"
  if (Test-Path -LiteralPath $fallback) {
    return $fallback
  }

  throw "GitHub CLI is not installed"
}

function Resolve-GitHubRepository {
  $configured = [string](Get-OptionalProperty $script:Config "githubRepository" "")
  if ($configured) {
    $normalized = $configured.Trim().Trim("/") -replace '\.git$', ''
  }
  else {
    $remoteUrl = Invoke-Captured "git" @("remote", "get-url", [string]$script:Config.remote)
    $match = [regex]::Match($remoteUrl, '^(?:https?|ssh)://(?:(?:[^@/]+)@)?(?<host>[^/:]+)(?::\d+)?/(?<owner>[^/]+)/(?<repo>[^/]+?)(?:\.git)?/?$')
    if (-not $match.Success) {
      $match = [regex]::Match($remoteUrl, '^(?:[^@]+@)?(?<host>[^:]+):(?<owner>[^/]+)/(?<repo>[^/]+?)(?:\.git)?$')
    }
    if (-not $match.Success) {
      throw "Cannot derive GitHub repository from remote '$remoteUrl'; set githubRepository to OWNER/REPO"
    }
    $host = $match.Groups["host"].Value.ToLowerInvariant()
    $owner = $match.Groups["owner"].Value
    $repo = $match.Groups["repo"].Value -replace '\.git$', ''
    $normalized = if ($host -eq "github.com") { "$owner/$repo" } else { "$host/$owner/$repo" }
  }

  $parts = @($normalized -split "/")
  if ($parts.Count -eq 2) {
    $script:GitHubHost = "github.com"
  }
  elseif ($parts.Count -eq 3) {
    $script:GitHubHost = $parts[0]
  }
  else {
    throw "githubRepository must use OWNER/REPO or HOST/OWNER/REPO"
  }
  $script:GitHubRepository = $normalized
}

function Invoke-GitHubChecked([string[]]$Arguments) {
  Invoke-Checked $script:GitHubCli (@($Arguments) + @("--repo", $script:GitHubRepository))
}

function Invoke-GitHubCaptured([string[]]$Arguments) {
  return Invoke-Captured $script:GitHubCli (@($Arguments) + @("--repo", $script:GitHubRepository))
}

function Assert-GitHubAuth {
  $script:GitHubCli = Resolve-GitHubCli
  Resolve-GitHubRepository
  Invoke-Checked $script:GitHubCli @("auth", "status", "--hostname", $script:GitHubHost)
}

function Disable-StaleLoopbackProxy {
  $proxyValue = @($env:HTTPS_PROXY, $env:HTTP_PROXY) |
    Where-Object { $_ } |
    Select-Object -First 1
  if (-not $proxyValue) {
    return
  }

  try {
    $proxyUri = [Uri]$proxyValue
  }
  catch {
    return
  }

  if ($proxyUri.Host -notin @("127.0.0.1", "localhost", "::1")) {
    return
  }

  $client = New-Object Net.Sockets.TcpClient
  $reachable = $false
  try {
    $reachable = $client.ConnectAsync($proxyUri.Host, $proxyUri.Port).Wait(750) -and $client.Connected
  }
  catch {
    $reachable = $false
  }
  finally {
    $client.Dispose()
  }

  if (-not $reachable) {
    Write-Warning "Ignoring stale loopback proxy $proxyValue for GitHub CLI"
    $env:HTTP_PROXY = $null
    $env:HTTPS_PROXY = $null
  }
}


function Find-WorkflowRun($Workflow, [string]$HeadSha) {
  $timeoutSeconds = [int](Get-OptionalProperty $Workflow "findTimeoutSeconds" 120)
  $event = [string](Get-OptionalProperty $Workflow "event" "push")
  $deadline = [DateTime]::UtcNow.AddSeconds($timeoutSeconds)
  while ([DateTime]::UtcNow -lt $deadline) {
    $json = Invoke-GitHubCaptured @(
      "run", "list",
      "--workflow", [string]$Workflow.name,
      "--event", $event,
      "--commit", $HeadSha,
      "--limit", "30",
      "--json", "databaseId,headBranch,headSha,status,url"
    )
    $run = Select-WorkflowRun -Json $json -Tag $script:Tag -HeadSha $HeadSha
    if ($run) {
      return $run
    }
    Start-Sleep -Seconds 5
  }
  throw "Timed out waiting for workflow $($Workflow.name) for $($script:Tag)"
}

function Wait-WorkflowRun($Workflow, [long]$RunId) {
  $waitMinutes = [int](Get-OptionalProperty $Workflow "waitTimeoutMinutes" 90)
  $deadline = [DateTime]::UtcNow.AddMinutes($waitMinutes)
  $previousSignature = $null
  $lastReadError = $null
  $previousReadError = $null

  while ([DateTime]::UtcNow -lt $deadline) {
    try {
      $json = Invoke-GitHubCaptured @(
        "run", "view", [string]$RunId,
        "--json", "status,conclusion,url,jobs"
      )
      $run = ConvertFrom-Json -InputObject $json
      $lastReadError = $null
      $previousReadError = $null
    }
    catch {
      $lastReadError = $_.Exception.Message
      if ($lastReadError -ne $previousReadError) {
        Write-Warning "Workflow status read failed; retrying: $lastReadError"
        $previousReadError = $lastReadError
      }
      Start-Sleep -Seconds 10
      continue
    }

    $snapshot = Get-WorkflowRunSnapshot -Run $run
    if (Test-WorkflowSnapshotChanged -PreviousSignature $previousSignature -Snapshot $snapshot) {
      Write-Host $snapshot.Message
      $previousSignature = $snapshot.Signature
    }
    if ($snapshot.State -eq "Failed") {
      throw $snapshot.Message
    }
    if ($snapshot.State -eq "Succeeded") {
      return $run
    }
    Start-Sleep -Seconds 10
  }

  if ($lastReadError) {
    throw "Timed out waiting for workflow $RunId; last read error: $lastReadError"
  }
  throw "Timed out waiting for workflow $RunId"
}

function Assert-ReleaseAssets($RequiredAssets, [object[]]$Assets) {
  $names = @($Assets | ForEach-Object { [string]$_.name })
  if (@($names | Group-Object | Where-Object { $_.Count -gt 1 }).Count -gt 0) {
    throw "Release contains duplicate asset names"
  }
  foreach ($check in @($RequiredAssets)) {
    $pattern = [string](Get-RequiredProperty $check "pattern" "publish.release.requiredAssets[]")
    $label = [string](Get-OptionalProperty $check "label" $pattern)
    if (-not ($names | Where-Object { $_ -match $pattern })) {
      throw "Release asset missing: $label"
    }
  }
}

function Assert-ReleaseAssetIntegrity($Release, [string[]]$ExpectedLocalPaths = @()) {
  $assets = @($Release.assets)
  if ($assets.Count -eq 0) { throw "Release contains no assets to verify" }
  $expectedByName = @{}
  foreach ($path in @($ExpectedLocalPaths)) {
    $file = Get-Item -LiteralPath $path
    if ($expectedByName.ContainsKey($file.Name)) { throw "Upload assets contain duplicate file name: $($file.Name)" }
    $expectedByName[$file.Name] = [pscustomobject]@{
      Length = [long]$file.Length
      SHA256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName).Hash.ToLowerInvariant()
    }
  }

  foreach ($asset in $assets) {
    $name = [string]$asset.name
    if ([string]::IsNullOrWhiteSpace($name) -or $name -ne [IO.Path]::GetFileName($name)) {
      throw "Release asset has an unsafe name: $name"
    }
    if ($asset.PSObject.Properties["state"] -and [string]$asset.state -ne "uploaded") {
      throw "Release asset is not fully uploaded: $name"
    }
    if ([long]$asset.size -le 0) { throw "Release asset is empty: $name" }
    $digest = [string]$asset.digest
    $digestMatch = [regex]::Match($digest, '^sha256:(?<hash>[0-9a-fA-F]{64})$')
    if (-not $digestMatch.Success) {
      throw "Release asset lacks a valid SHA256 digest: $name"
    }
    if ($expectedByName.ContainsKey($name)) {
      $expected = $expectedByName[$name]
      if ([long]$asset.size -ne [long]$expected.Length) { throw "Release asset size differs from local upload: $name" }
      if ($digestMatch.Groups["hash"].Value.ToLowerInvariant() -ne [string]$expected.SHA256) { throw "Release asset SHA256 differs from local upload: $name" }
    }
  }
  if ($expectedByName.Count -gt 0) {
    $remoteNames = @($assets | ForEach-Object { [string]$_.name })
    foreach ($name in $expectedByName.Keys) {
      if ($remoteNames -notcontains $name) { throw "Uploaded release asset missing from draft: $name" }
    }
    foreach ($name in $remoteNames) {
      if (-not $expectedByName.ContainsKey($name)) { throw "Draft release contains an unexpected asset: $name" }
    }
  }

  $downloadRoot = Join-Path ([IO.Path]::GetTempPath()) ("auto-release-assets-" + [guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Path $downloadRoot | Out-Null
  try {
    Invoke-GitHubChecked @("release", "download", $script:Tag, "--dir", $downloadRoot)
    $downloaded = @(Get-ChildItem -LiteralPath $downloadRoot -File)
    if ($downloaded.Count -ne $assets.Count) {
      throw "Downloaded release asset count differs from GitHub metadata"
    }
    foreach ($asset in $assets) {
      $name = [string]$asset.name
      $file = @($downloaded | Where-Object { $_.Name -ceq $name }) | Select-Object -First 1
      if (-not $file) { throw "Downloaded release asset missing: $name" }
      if ([long]$file.Length -ne [long]$asset.size) { throw "Downloaded release asset size mismatch: $name" }
      $remoteHash = ([string]$asset.digest).Substring(7).ToLowerInvariant()
      $downloadHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName).Hash.ToLowerInvariant()
      if ($downloadHash -ne $remoteHash) { throw "Downloaded release asset SHA256 mismatch: $name" }
      Write-Host "Verified release asset: $name SHA256 $downloadHash"
    }
  }
  finally {
    if (Test-Path -LiteralPath $downloadRoot -PathType Container) {
      Remove-Item -LiteralPath $downloadRoot -Recurse -Force
    }
  }
}

function Resolve-UploadAssets($ReleaseConfig) {
  $resolved = @()
  foreach ($configuredPath in @(Get-OptionalProperty $ReleaseConfig "uploadAssets" @())) {
    $relativePattern = Expand-ConfigTokens ([string]$configuredPath)
    if (
      [IO.Path]::IsPathRooted($relativePattern) -or
      $relativePattern -match '(^|[\\/])\.\.([\\/]|$)'
    ) {
      throw "Upload asset pattern must stay inside the repository: $relativePattern"
    }
    $matches = @(Get-ChildItem -Path (Join-Path $script:ResolvedRepositoryRoot $relativePattern) -File)
    if ($matches.Count -eq 0) {
      throw "Upload asset pattern matched no files: $relativePattern"
    }
    foreach ($match in $matches) {
      $resolved += Assert-PathInsideRepository $match.FullName
    }
  }
  return @($resolved | Sort-Object -Unique)
}

function Invoke-ReleasePublication([string]$ReleaseNotes) {
  $releaseConfig = $script:Config.publish.release
  $releaseMode = [string]$releaseConfig.mode
  if ($releaseMode -eq "none") {
    Write-Host "Tag pushed; GitHub Release creation disabled by config"
    return
  }

  $titleTemplate = [string](Get-OptionalProperty $releaseConfig "title" "{projectName} {tag}")
  $title = Expand-ConfigTokens $titleTemplate

  if ($releaseMode -eq "publish-draft") {
    $releaseJson = Invoke-GitHubCaptured @(
      "release", "view", $script:Tag,
      "--json", "isDraft,url,assets"
    )
    $release = $releaseJson | ConvertFrom-Json
    Assert-ReleaseAssets `
      (Get-OptionalProperty $releaseConfig "requiredAssets" @()) `
      @($release.assets)
    Assert-ReleaseAssetIntegrity -Release $release

    if (-not $release.isDraft) {
      Write-Host "Release already public and verified: $($release.url)"
      return
    }

    Invoke-GitHubChecked @(
      "release", "edit", $script:Tag,
      "--title", $title,
      "--notes", $ReleaseNotes,
      "--draft=false",
      "--verify-tag"
    )
    Write-Host "Release published: $($release.url)"
    return
  }

  $uploadAssets = Resolve-UploadAssets $releaseConfig
  $release = $null
  try {
    $release = (Invoke-GitHubCaptured @(
      "release", "view", $script:Tag,
      "--json", "isDraft,url,assets"
    )) | ConvertFrom-Json
  }
  catch {
    $release = $null
  }
  if (-not $release) {
    $arguments = @("release", "create", $script:Tag)
    $arguments += $uploadAssets
    $arguments += @("--title", $title, "--notes", $ReleaseNotes, "--draft", "--verify-tag")
    Invoke-GitHubChecked $arguments
    $release = (Invoke-GitHubCaptured @(
      "release", "view", $script:Tag,
      "--json", "isDraft,url,assets"
    )) | ConvertFrom-Json
  }

  Assert-ReleaseAssets `
    (Get-OptionalProperty $releaseConfig "requiredAssets" @()) `
    @($release.assets)
  Assert-ReleaseAssetIntegrity -Release $release -ExpectedLocalPaths $uploadAssets
  if (-not $release.isDraft) {
    Write-Host "Release already public and verified: $($release.url)"
    return
  }
  Invoke-GitHubChecked @(
    "release", "edit", $script:Tag,
    "--title", $title,
    "--notes", $ReleaseNotes,
    "--draft=false",
    "--verify-tag"
  )
  Write-Host "Release published: $($release.url)"
}
