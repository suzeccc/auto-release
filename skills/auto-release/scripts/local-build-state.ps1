# Internal source fingerprints, local build receipts, and stable rebuilds.

function Get-CurrentVersion($Config) {
  $read = $Config.version.read
  $path = Resolve-RepositoryPath ([string]$read.path)
  $match = [regex]::Match([IO.File]::ReadAllText($path), [string]$read.pattern)
  if (-not $match.Success -or -not $match.Groups["version"].Success) { throw "Cannot read the current project version" }
  return $match.Groups["version"].Value
}
function Get-VersionPatternsByPath($Config) {
  $patterns = @{}
  $readPath = ([string]$Config.version.read.path).Replace("\", "/")
  $patterns[$readPath] = @([string]$Config.version.read.pattern)
  foreach ($update in @(Get-OptionalProperty $Config.version "updates" @())) {
    $path = ([string]$update.path).Replace("\", "/")
    if (-not $patterns.ContainsKey($path)) { $patterns[$path] = @() }
    $patterns[$path] += [string]$update.pattern
  }
  return $patterns
}

function Get-NormalizedFileHash([string]$RelativePath, $VersionPatterns) {
  $fullPath = Resolve-RepositoryPath $RelativePath
  if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { return "missing" }
  if ($VersionPatterns.ContainsKey($RelativePath)) {
    $content = [IO.File]::ReadAllText($fullPath)
    foreach ($pattern in @($VersionPatterns[$RelativePath])) {
      try {
        $regex = [regex]::new($pattern)
        $content = $regex.Replace($content, {
          param($match)
          return ([regex]::new('\d+\.\d+\.\d+')).Replace($match.Value, '<release-version>', 1)
        })
      }
      catch { throw "Invalid version fingerprint pattern for ${RelativePath}: $pattern" }
    }
    $bytes = $script:Utf8NoBom.GetBytes($content)
  }
  else {
    $bytes = [IO.File]::ReadAllBytes($fullPath)
  }
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "") }
  finally { $sha.Dispose() }
}

function Get-SourceFingerprint($Config) {
  $tracked = @((Invoke-GitCaptured @("ls-files")) -split "`r?`n" | Where-Object { $_ })
  $untracked = @((Invoke-GitCaptured @("ls-files", "--others", "--exclude-standard")) -split "`r?`n" | Where-Object { $_ })
  $untracked = @($untracked | Where-Object {
    $_.Replace("\", "/") -notmatch '(^|/)(?:\.venv|bin|build|dist|node_modules|obj|out|output|release|target|vendor|venv)(/|$)'
  })
  $patterns = Get-VersionPatternsByPath $Config
  $entries = @()
  foreach ($path in @($tracked + $untracked | Sort-Object -Unique)) {
    $normalized = $path.Replace("\", "/")
    $entries += "$normalized`:$((Get-NormalizedFileHash $normalized $patterns))"
  }
  $payload = $script:Utf8NoBom.GetBytes(($entries -join "`n"))
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return ([BitConverter]::ToString($sha.ComputeHash($payload))).Replace("-", "") }
  finally { $sha.Dispose() }
}

function Get-ReceiptPath([string]$DirectoryName = "auto-release", [bool]$CreateDirectory = $true) {
  $directory = Join-Path (Get-GitDirectory) $DirectoryName
  if ($CreateDirectory -and -not (Test-Path -LiteralPath $directory -PathType Container)) {
    New-Item -ItemType Directory -Path $directory | Out-Null
  }
  return Join-Path $directory "local-build.json"
}

function Read-LocalBuildReceipt {
  $path = Get-ReceiptPath "auto-release" $false
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    $path = Get-ReceiptPath "project-release-automator" $false
  }
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
  try { return Get-Content -Raw -Encoding UTF8 -LiteralPath $path | ConvertFrom-Json }
  catch { return $null }
}

function Get-ReceiptArtifactPaths {
  $receipt = Read-LocalBuildReceipt
  if (-not $receipt) { return @() }
  return @($receipt.artifacts | ForEach-Object { [string]$_.path } | Where-Object { $_ })
}

function Get-ArtifactManifestPath {
  $directory = Split-Path -Parent (Get-ReceiptPath)
  return Join-Path $directory "artifacts.json"
}

function Expand-ArtifactToken([string]$Value, $Config, [string]$CurrentVersion) {
  $prefix = [string](Get-OptionalProperty $Config "tagPrefix" "v")
  return $Value.Replace("{projectName}", [string]$Config.projectName).
    Replace("{version}", $CurrentVersion).
    Replace("{tag}", "$prefix$CurrentVersion")
}

function Get-LocalArtifactRecords($Config, [string]$ManifestPath = "") {
  if ($ManifestPath -and (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
    try { $manifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $ManifestPath | ConvertFrom-Json }
    catch { throw "Local artifact manifest is invalid: $ManifestPath" }
    $manifestRecords = @($manifest.artifacts)
    foreach ($record in $manifestRecords) {
      $path = Resolve-RepositoryPath ([string]$record.path)
      if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Manifest artifact not found: $($record.path)"
      }
      $record.sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash
    }
    return @($manifestRecords | Select-Object path, sha256 | Sort-Object path -Unique)
  }
  $records = @()
  $currentVersion = Get-CurrentVersion $Config
  $outputRelative = [string](Get-OptionalProperty $Config.prepare "localOutputDirectory" "output")
  if ([string]::IsNullOrWhiteSpace($outputRelative)) { $outputRelative = "output" }
  $outputPath = Resolve-RepositoryPath $outputRelative
  if (Test-Path -LiteralPath $outputPath -PathType Container) {
    foreach ($file in @(Get-ChildItem -LiteralPath $outputPath -File)) {
      $relative = $file.FullName.Substring($script:ResolvedRepositoryRoot.Length + 1).Replace("\", "/")
      $records += [pscustomobject]@{
        path = $relative
        sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName).Hash
      }
    }
  }
  if ($records.Count -gt 0) {
    return @($records | Sort-Object path -Unique)
  }

  foreach ($artifact in @(Get-OptionalProperty $Config.prepare "artifacts" @())) {
    $relative = Expand-ArtifactToken ([string](Get-OptionalProperty $artifact "destination" $artifact.source)) $Config $currentVersion
    $path = Resolve-RepositoryPath $relative
    if (Test-Path -LiteralPath $path -PathType Leaf) {
      $records += [pscustomobject]@{ path = $relative.Replace("\", "/"); sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash }
    }
  }
  if ($records.Count -eq 0) {
    $extensions = switch ([string]$Config.projectType) {
      "tauri" { @(".exe", ".msi", ".dmg", ".appimage", ".deb", ".rpm") }
      "node" { @(".tgz") }
      "electron" { @(".exe", ".zip", ".dmg", ".appimage") }
      "go" { @(".exe") }
      "python" { @(".whl", ".gz") }
      "rust" { @(".crate", ".exe") }
      "dotnet" { @(".nupkg", ".exe") }
      "java" { @(".jar") }
      "cmake" { @(".exe", ".zip") }
      "flutter" { @(".exe", ".apk", ".aab", ".zip") }
      "android" { @(".apk", ".aab") }
      default { @() }
    }
    foreach ($rootName in @("dist", "build", "out", "release", "target", "src-tauri\target\release")) {
      $rootPath = Join-Path $script:ResolvedRepositoryRoot $rootName
      if (-not (Test-Path -LiteralPath $rootPath -PathType Container)) { continue }
      foreach ($file in Get-ChildItem -LiteralPath $rootPath -Recurse -File | Where-Object { $extensions -contains $_.Extension.ToLowerInvariant() } | Select-Object -First 200) {
        $relative = $file.FullName.Substring($script:ResolvedRepositoryRoot.Length + 1).Replace("\", "/")
        $records += [pscustomobject]@{ path = $relative; sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName).Hash }
      }
    }
  }
  return @($records | Sort-Object path -Unique)
}

function Remove-StaleManagedArtifacts($Config, [string[]]$PreviousPaths, $CurrentArtifacts) {
  $outputRelative = [string](Get-OptionalProperty $Config.prepare "localOutputDirectory" "output")
  if ([string]::IsNullOrWhiteSpace($outputRelative)) { $outputRelative = "output" }
  $outputRoot = Resolve-RepositoryPath $outputRelative
  $outputPrefix = $outputRoot + [IO.Path]::DirectorySeparatorChar
  $current = @{}
  foreach ($artifact in @($CurrentArtifacts)) {
    $current[([string]$artifact.path).Replace("\", "/").ToLowerInvariant()] = $true
  }
  foreach ($relativePath in @($PreviousPaths | Where-Object { $_ })) {
    $key = $relativePath.Replace("\", "/").ToLowerInvariant()
    if ($current.ContainsKey($key)) { continue }
    $path = Resolve-RepositoryPath $relativePath
    if (-not $path.StartsWith($outputPrefix, [StringComparison]::OrdinalIgnoreCase)) { continue }
    if (Test-Path -LiteralPath $path -PathType Leaf) {
      Remove-Item -LiteralPath $path -Force
      Write-Host "Removed stale managed local artifact: $relativePath"
    }
  }
}

function Write-LocalBuildReceipt(
  $Config,
  [string]$ManifestPath = "",
  [string[]]$PreviousPaths = @(),
  [bool]$PruneStaleArtifacts = $false
) {
  $artifacts = @(Get-LocalArtifactRecords $Config $ManifestPath)
  if ($PruneStaleArtifacts) {
    Remove-StaleManagedArtifacts $Config $PreviousPaths $artifacts
  }
  $receipt = [pscustomobject][ordered]@{
    schemaVersion = 1
    projectType = [string]$Config.projectType
    sourceFingerprint = Get-SourceFingerprint $Config
    currentVersion = Get-CurrentVersion $Config
    builtAtUtc = [DateTime]::UtcNow.ToString("o")
    artifacts = $artifacts
  }
  [IO.File]::WriteAllText((Get-ReceiptPath), (($receipt | ConvertTo-Json -Depth 10) + "`n"), $script:Utf8NoBom)
  if ($artifacts.Count -eq 0) { Write-Warning "Local build succeeded, but no verifiable local artifact was found; release will rebuild locally" }
  else { Write-Host "Recorded local build receipt with $($artifacts.Count) artifact(s)" }
}

function Test-LocalBuildFresh($Config) {
  $receipt = Read-LocalBuildReceipt
  if (-not $receipt) { return $false }
  if ([string]$receipt.projectType -ne [string]$Config.projectType) { return $false }
  if ([string]$receipt.sourceFingerprint -ne (Get-SourceFingerprint $Config)) { return $false }
  $artifacts = @($receipt.artifacts)
  if ($artifacts.Count -eq 0) { return $false }
  foreach ($artifact in $artifacts) {
    $artifactPath = Resolve-RepositoryPath ([string]$artifact.path)
    if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) { return $false }
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $artifactPath).Hash -ne [string]$artifact.sha256) { return $false }
  }
  return $true
}

function Invoke-StableReleaseBuild($Config, [string]$ManifestPath) {
  for ($attempt = 1; $attempt -le 2; $attempt++) {
    $before = Get-SourceFingerprint $Config
    if (Test-Path -LiteralPath $ManifestPath -PathType Leaf) {
      Remove-Item -LiteralPath $ManifestPath -Force
    }
    $canonicalLocalOutput = [string](Get-OptionalProperty $Config.publish.release "mode" "none") -eq "publish-draft"
    & $releaseScript -Mode Prepare -Version $Version -Summary $Summary `
      -RepositoryRoot $script:ResolvedRepositoryRoot -ConfigPath $ConfigPath `
      -ArtifactManifestPath $ManifestPath -CanonicalLocalOutput:$canonicalLocalOutput | Out-Host
    $Config = Read-ReleaseConfig
    $after = Get-SourceFingerprint $Config
    if ($before -eq $after) {
      Write-LocalBuildReceipt $Config $ManifestPath
      return [pscustomobject]@{ Config = $Config; Fingerprint = $after }
    }
    if ($attempt -lt 2) {
      Write-Warning "Source files changed during the verified build; rebuilding once with the new state"
    }
  }
  throw "Source files kept changing during the verified build; release stopped"
}
