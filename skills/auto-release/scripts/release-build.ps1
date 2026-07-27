# Internal dependency preparation, local artifact discovery, and manifests.

function Get-GitDirectory {
  $path = Invoke-Captured "git" @("rev-parse", "--git-dir")
  if (-not [IO.Path]::IsPathRooted($path)) {
    $path = Join-Path $script:ResolvedRepositoryRoot $path
  }
  return Get-NormalizedPath $path
}
function Get-BootstrapFingerprint {
  $prepare = $script:Config.prepare
  $entries = @()
  foreach ($command in @(Get-OptionalProperty $prepare "bootstrapCommands" @())) {
    $commandText = [string]$command.command
    $entries += "command:$([string]$command.name):$commandText"
    $toolMatch = [regex]::Match($commandText, '^\s*(?:"(?<quoted>[^"]+)"|(?<bare>[^\s&]+))')
    $toolName = if ($toolMatch.Groups["quoted"].Success) { $toolMatch.Groups["quoted"].Value } else { $toolMatch.Groups["bare"].Value }
    $tool = if ($toolName) { Get-Command $toolName -ErrorAction SilentlyContinue } else { $null }
    if ($tool) {
      $toolPath = [string]$tool.Source
      $toolVersion = if ($toolPath -and (Test-Path -LiteralPath $toolPath -PathType Leaf)) {
        [string](Get-Item -LiteralPath $toolPath).VersionInfo.FileVersion
      }
      else { "" }
      $entries += "tool:$toolName`:$toolPath`:$toolVersion"
    }
    else {
      $entries += "tool:$toolName`:missing"
    }
  }
  $versionPatterns = @{}
  $readPath = ([string]$script:Config.version.read.path).Replace("\", "/")
  $versionPatterns[$readPath] = @([string]$script:Config.version.read.pattern)
  foreach ($update in @(Get-OptionalProperty $script:Config.version "updates" @())) {
    $updatePath = ([string]$update.path).Replace("\", "/")
    if (-not $versionPatterns.ContainsKey($updatePath)) { $versionPatterns[$updatePath] = @() }
    $versionPatterns[$updatePath] += [string]$update.pattern
  }
  foreach ($relativePath in @(Get-OptionalProperty $prepare "bootstrapInputs" @()) | Sort-Object -Unique) {
    $path = Resolve-RepositoryPath ([string]$relativePath)
    $hash = if (Test-Path -LiteralPath $path -PathType Leaf) {
      $normalizedRelative = ([string]$relativePath).Replace("\", "/")
      if ($versionPatterns.ContainsKey($normalizedRelative)) {
        $content = [IO.File]::ReadAllText($path)
        foreach ($pattern in @($versionPatterns[$normalizedRelative])) {
          $regex = [regex]::new($pattern)
          $content = $regex.Replace($content, {
            param($match)
            return ([regex]::new('\d+\.\d+\.\d+')).Replace($match.Value, '<release-version>', 1)
          })
        }
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($content)
        $sha = [Security.Cryptography.SHA256]::Create()
        try { ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "") }
        finally { $sha.Dispose() }
      }
      else {
        (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash
      }
    }
    else {
      "missing"
    }
    $entries += "input:$(([string]$relativePath).Replace('\', '/')):$hash"
  }
  $payload = [Text.UTF8Encoding]::new($false).GetBytes(($entries -join "`n"))
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return ([BitConverter]::ToString($sha.ComputeHash($payload))).Replace("-", "") }
  finally { $sha.Dispose() }
}

function Invoke-CommandList($Commands, [bool]$Parallel) {
  $expanded = @(
    @($Commands) | ForEach-Object {
      [pscustomobject]@{
        name = Expand-ConfigTokens ([string]$_.name)
        command = Expand-ConfigTokens ([string]$_.command)
      }
    }
  )
  if ($expanded.Count -eq 0) { return }
  if ($Parallel) {
    Invoke-ParallelShellChecked -WorkingDirectory $script:ResolvedRepositoryRoot -Commands $expanded
  }
  else {
    Invoke-SequentialShellChecked -WorkingDirectory $script:ResolvedRepositoryRoot -Commands $expanded
  }
}

function Invoke-BootstrapCommands {
  $prepare = $script:Config.prepare
  $commands = @(Get-OptionalProperty $prepare "bootstrapCommands" @())
  if ($commands.Count -eq 0) { return }

  $fingerprint = Get-BootstrapFingerprint
  $stateDirectory = Join-Path (Get-GitDirectory) "auto-release"
  $statePath = Join-Path $stateDirectory "bootstrap.json"
  if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    try { $state = Get-Content -Raw -Encoding UTF8 -LiteralPath $statePath | ConvertFrom-Json }
    catch { $state = $null }
    $requiredPathsExist = @(
      @(Get-OptionalProperty $prepare "bootstrapRequiredPaths" @()) | Where-Object {
        -not (Test-Path -LiteralPath (Resolve-RepositoryPath ([string]$_)))
      }
    ).Count -eq 0
    if ($state -and [string]$state.fingerprint -eq $fingerprint -and $requiredPathsExist) {
      Write-Host "Dependency bootstrap is current; skipping installation"
      return
    }
  }

  Invoke-CommandList $commands $false
  New-Item -ItemType Directory -Force -Path $stateDirectory | Out-Null
  $state = [pscustomobject][ordered]@{
    schemaVersion = 1
    fingerprint = $fingerprint
    completedAtUtc = [DateTime]::UtcNow.ToString("o")
  }
  Write-Utf8NoBom $statePath (($state | ConvertTo-Json -Depth 5) + "`n")
}

function Invoke-ConfiguredCommands([bool]$LocalBuild = $false) {
  $prepare = $script:Config.prepare
  Invoke-BootstrapCommands
  $commands = if ($LocalBuild -and $null -ne $prepare.PSObject.Properties["localCommands"]) {
    @(Get-OptionalProperty $prepare "localCommands" @())
  }
  else {
    @(Get-OptionalProperty $prepare "commands" @())
  }
  Invoke-CommandList $commands ([bool](Get-OptionalProperty $prepare "parallel" $false))
}

function ConvertTo-LocalOutputStem {
  $name = [string]$script:Config.projectName
  foreach ($character in [IO.Path]::GetInvalidFileNameChars()) {
    $name = $name.Replace([string]$character, "-")
  }
  $name = $name.Trim().TrimEnd(".")
  if ([string]::IsNullOrWhiteSpace($name)) { return "app" }
  return $name
}

function Get-LocalArtifactExtension([IO.FileInfo]$File) {
  $lowerName = $File.Name.ToLowerInvariant()
  foreach ($extension in @(".tar.gz", ".appimage", ".nupkg", ".crate", ".whl", ".tgz", ".aab", ".apk", ".msi", ".dmg", ".deb", ".rpm", ".jar", ".zip", ".exe")) {
    if ($lowerName.EndsWith($extension, [StringComparison]::Ordinal)) { return $extension }
  }
  return $File.Extension.ToLowerInvariant()
}

function ConvertTo-RepositoryRelativePath([string]$Path) {
  $fullPath = Get-NormalizedPath $Path
  $prefix = $script:ResolvedRepositoryRoot + [IO.Path]::DirectorySeparatorChar
  if (-not $fullPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Artifact is outside the repository: $Path"
  }
  return $fullPath.Substring($prefix.Length).Replace("\", "/")
}

function Get-PreferredLocalFile($Files) {
  $candidates = @($Files | Where-Object { $_ -and $_.Exists })
  if ($candidates.Count -eq 0) { return $null }
  $stem = ConvertTo-LocalOutputStem
  $sorted = @($candidates | Sort-Object @{ Expression = {
    if ($_.BaseName.Equals($stem, [StringComparison]::OrdinalIgnoreCase)) { 0 }
    elseif ($_.BaseName.IndexOf($stem, [StringComparison]::OrdinalIgnoreCase) -ge 0) { 1 }
    else { 2 }
  } }, @{ Expression = { $_.LastWriteTimeUtc }; Descending = $true })
  return $sorted[0]
}

function Get-DiscoveredLocalArtifactFiles {
  $type = [string](Get-OptionalProperty $script:Config "projectType" "")
  $files = @()
  if ($type -eq "tauri") {
    $root = Resolve-RepositoryPath "src-tauri/target/release"
    if (Test-Path -LiteralPath $root -PathType Container) {
      $preferred = Get-PreferredLocalFile @(Get-ChildItem -LiteralPath $root -File -Filter "*.exe")
      if ($preferred) { $files += $preferred }
    }
  }
  elseif ($type -eq "node") {
    $root = Resolve-RepositoryPath "dist"
    if (Test-Path -LiteralPath $root -PathType Container) {
      $preferred = Get-PreferredLocalFile @(Get-ChildItem -LiteralPath $root -File -Filter "*.tgz")
      if ($preferred) { $files += $preferred }
    }
  }
  elseif ($type -eq "go") {
    $root = Resolve-RepositoryPath "dist"
    if (Test-Path -LiteralPath $root -PathType Container) {
      $preferred = Get-PreferredLocalFile @(Get-ChildItem -LiteralPath $root -File -Filter "*.exe")
      if ($preferred) { $files += $preferred }
    }
  }
  elseif ($type -eq "python") {
    $root = Resolve-RepositoryPath "dist"
    if (Test-Path -LiteralPath $root -PathType Container) {
      foreach ($filter in @("*.whl", "*.tar.gz")) {
        $preferred = Get-PreferredLocalFile @(Get-ChildItem -LiteralPath $root -File -Filter $filter)
        if ($preferred) { $files += $preferred }
      }
    }
  }
  elseif ($type -eq "rust") {
    $releaseRoot = Resolve-RepositoryPath "target/release"
    if (Test-Path -LiteralPath $releaseRoot -PathType Container) {
      $preferred = Get-PreferredLocalFile @(Get-ChildItem -LiteralPath $releaseRoot -File -Filter "*.exe")
      if (-not $preferred) {
        $depsRoot = Join-Path $releaseRoot "deps"
        if (Test-Path -LiteralPath $depsRoot -PathType Container) {
          $preferred = Get-PreferredLocalFile @(Get-ChildItem -LiteralPath $depsRoot -File -Filter "*.rlib")
        }
      }
      if ($preferred) { $files += $preferred }
    }
    if ($files.Count -eq 0) {
      $root = Resolve-RepositoryPath "target/package"
      if (Test-Path -LiteralPath $root -PathType Container) {
        $preferred = Get-PreferredLocalFile @(Get-ChildItem -LiteralPath $root -File -Filter "*.crate")
        if ($preferred) { $files += $preferred }
      }
    }
  }
  elseif ($type -eq "dotnet") {
    $searchRoots = @(Get-OptionalProperty $script:Config.prepare "localSearchRoots" @("bin/Release"))
    foreach ($relativeRoot in $searchRoots) {
      $binRoot = Resolve-RepositoryPath ([string]$relativeRoot)
      if (Test-Path -LiteralPath $binRoot -PathType Container) {
        $preferred = Get-PreferredLocalFile @(Get-ChildItem -LiteralPath $binRoot -Recurse -File -Filter "*.exe")
        if (-not $preferred) {
          $preferred = Get-PreferredLocalFile @(Get-ChildItem -LiteralPath $binRoot -Recurse -File -Filter "*.dll" | Where-Object {
            $_.FullName -notmatch '[\\/](?:ref|runtimes)[\\/]'
          })
        }
        if ($preferred) { $files += $preferred; break }
      }
    }
    if ($files.Count -eq 0) {
      $root = Resolve-RepositoryPath "dist"
      if (Test-Path -LiteralPath $root -PathType Container) {
        $preferred = Get-PreferredLocalFile @(Get-ChildItem -LiteralPath $root -File -Filter "*.nupkg")
        if ($preferred) { $files += $preferred }
      }
    }
  }
  elseif ($type -eq "java") {
    $candidates = @()
    foreach ($relativeRoot in @("target", "build/libs")) {
      $root = Resolve-RepositoryPath $relativeRoot
      if (Test-Path -LiteralPath $root -PathType Container) {
        $candidates += @(Get-ChildItem -LiteralPath $root -File -Filter "*.jar" | Where-Object {
          $_.Name -notmatch '(?i)(?:-sources|-javadoc|-tests)\.jar$' -and $_.Name -notmatch '(?i)^original-'
        })
      }
    }
    $preferred = Get-PreferredLocalFile $candidates
    if ($preferred) { $files += $preferred }
  }
  elseif ($type -eq "cmake") {
    $root = Resolve-RepositoryPath "build"
    if (Test-Path -LiteralPath $root -PathType Container) {
      $candidates = @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter "*.exe" | Where-Object {
        $_.FullName -notmatch '[\\/]CMakeFiles[\\/]'
      })
      $preferred = Get-PreferredLocalFile $candidates
      if ($preferred) { $files += $preferred }
    }
  }
  elseif ($type -eq "flutter") {
    $root = Resolve-RepositoryPath "build/windows"
    if (Test-Path -LiteralPath $root -PathType Container) {
      $candidates = @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter "*.exe" | Where-Object {
        $_.FullName -match '[\\/]runner[\\/]Release[\\/]'
      })
      $preferred = Get-PreferredLocalFile $candidates
      if ($preferred) { $files += $preferred }
    }
  }
  elseif ($type -eq "android") {
    $candidates = @()
    foreach ($directory in @(Get-ChildItem -LiteralPath $script:ResolvedRepositoryRoot -Directory)) {
      $root = Join-Path $directory.FullName "build\outputs"
      if (Test-Path -LiteralPath $root -PathType Container) {
        foreach ($extension in @("*.apk", "*.aab")) {
          $preferred = Get-PreferredLocalFile @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter $extension)
          if ($preferred) { $candidates += $preferred }
        }
      }
    }
    $files += $candidates
  }
  elseif ($type -eq "electron") {
    $candidates = @()
    $searchRoots = @(Get-OptionalProperty $script:Config.prepare "localSearchRoots" @("dist", "out", "release"))
    foreach ($relativeRoot in $searchRoots) {
      $root = Resolve-RepositoryPath $relativeRoot
      if (Test-Path -LiteralPath $root -PathType Container) {
        $candidates += @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter "*.exe" | Where-Object {
          $_.Name -notmatch '(?i)uninstall'
        })
      }
    }
    $preferred = Get-PreferredLocalFile $candidates
    if ($preferred) { $files += $preferred }
  }
  return @($files | Sort-Object FullName -Unique)
}

function Stop-ProcessesUsingLocalArtifacts([string[]]$Paths) {
  if ($env:OS -ne "Windows_NT") { return }
  $targets = @{}
  foreach ($path in @($Paths | Where-Object { $_ })) {
    if ([IO.Path]::GetExtension($path) -ne ".exe") { continue }
    $targets[(Get-NormalizedPath $path).ToLowerInvariant()] = $true
  }
  if ($targets.Count -eq 0) { return }

  $stopped = @()
  foreach ($process in @(Get-Process)) {
    if ($process.Id -eq $PID) { continue }
    try { $processPath = [string]$process.Path }
    catch { continue }
    if (-not $processPath) { continue }
    $normalizedProcessPath = (Get-NormalizedPath $processPath).ToLowerInvariant()
    if (-not $targets.ContainsKey($normalizedProcessPath)) { continue }

    Write-Host "Stopping process $($process.ProcessName) ($($process.Id)) using local artifact: $processPath"
    try {
      Stop-Process -Id $process.Id -Force -ErrorAction Stop
      $stopped += [pscustomobject]@{ Id = $process.Id; Path = $processPath }
    }
    catch {
      if (Get-Process -Id $process.Id -ErrorAction SilentlyContinue) { throw }
    }
  }

  foreach ($entry in $stopped) {
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while (Get-Process -Id $entry.Id -ErrorAction SilentlyContinue) {
      if ([DateTime]::UtcNow -ge $deadline) {
        throw "Timed out stopping process $($entry.Id) using local artifact: $($entry.Path)"
      }
      Start-Sleep -Milliseconds 100
    }
  }
}

function Get-LocalBuildExecutablePaths {
  $paths = @()
  $prepare = $script:Config.prepare
  $artifactDefinitions = if ($null -ne $prepare.PSObject.Properties["localArtifacts"]) {
    @(Get-OptionalProperty $prepare "localArtifacts" @())
  }
  else {
    @(Get-OptionalProperty $prepare "artifacts" @())
  }
  $usedLocalNames = @{}
  foreach ($artifact in $artifactDefinitions) {
    $sourceRelative = Expand-ConfigTokens ([string]$artifact.source)
    $source = Resolve-RepositoryPath $sourceRelative
    $destination = Get-LocalArtifactDestination ([IO.FileInfo]::new($source)) $artifact $usedLocalNames
    if ([IO.Path]::GetExtension($source) -eq ".exe") { $paths += $source }
    if ([IO.Path]::GetExtension($destination) -eq ".exe") { $paths += $destination }
  }
  if ($artifactDefinitions.Count -eq 0) {
    foreach ($file in @(Get-DiscoveredLocalArtifactFiles)) {
      $destination = Get-LocalArtifactDestination $file ([pscustomobject]@{}) $usedLocalNames
      if ($file.Extension -eq ".exe") { $paths += $file.FullName }
      if ([IO.Path]::GetExtension($destination) -eq ".exe") { $paths += $destination }
    }
  }
  foreach ($relativePath in @($ManagedLocalArtifactPath)) {
    $path = Resolve-RepositoryPath $relativePath
    if ([IO.Path]::GetExtension($path) -eq ".exe") { $paths += $path }
  }
  return @($paths | Sort-Object -Unique)
}

function Stop-LocalBuildProcesses {
  Stop-ProcessesUsingLocalArtifacts @(Get-LocalBuildExecutablePaths)
}

function Get-LocalArtifactDestination([IO.FileInfo]$Source, $Artifact, [hashtable]$UsedNames) {
  $prepare = $script:Config.prepare
  $outputRelative = [string](Get-OptionalProperty $prepare "localOutputDirectory" "output")
  if ([string]::IsNullOrWhiteSpace($outputRelative)) { $outputRelative = "output" }
  $outputDirectory = Resolve-RepositoryPath $outputRelative
  New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null

  $extension = Get-LocalArtifactExtension $Source
  $localName = [string](Get-OptionalProperty $Artifact "localName" "")
  if ($localName) {
    if ([IO.Path]::GetFileName($localName) -ne $localName) {
      throw "prepare.artifacts[].localName must be a file name: $localName"
    }
  }
  else {
    $localName = "$(ConvertTo-LocalOutputStem)$extension"
  }

  $nameExtension = [IO.Path]::GetExtension($localName)
  if ($localName.EndsWith(".tar.gz", [StringComparison]::OrdinalIgnoreCase)) {
    $nameExtension = ".tar.gz"
  }
  $baseName = $localName.Substring(0, $localName.Length - $nameExtension.Length)
  $candidate = $localName
  $count = 1
  while ($UsedNames.ContainsKey($candidate.ToLowerInvariant())) {
    $count += 1
    $candidate = "$baseName-$count$nameExtension"
  }
  $localName = $candidate
  $UsedNames[$localName.ToLowerInvariant()] = $true
  return Join-Path $outputDirectory $localName
}

function Get-PreparedArtifacts([bool]$LocalBuild = $false) {
  $results = @()
  $artifactDefinitions = if ($LocalBuild -and $null -ne $script:Config.prepare.PSObject.Properties["localArtifacts"]) {
    @(Get-OptionalProperty $script:Config.prepare "localArtifacts" @())
  }
  else {
    @(Get-OptionalProperty $script:Config.prepare "artifacts" @())
  }
  if ($LocalBuild -and $artifactDefinitions.Count -eq 0) {
    foreach ($file in @(Get-DiscoveredLocalArtifactFiles)) {
      $artifactDefinitions += [pscustomobject][ordered]@{
        source = ConvertTo-RepositoryRelativePath $file.FullName
        sha256 = $true
      }
    }
  }
  if ($LocalBuild -and $artifactDefinitions.Count -eq 0) {
    Write-Warning "Build completed, but no file-based local artifact could be discovered"
    return @()
  }

  $usedLocalNames = @{}
  foreach ($artifact in $artifactDefinitions) {
    $sourceRelative = Expand-ConfigTokens ([string]$artifact.source)
    $source = Resolve-RepositoryPath $sourceRelative
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
      throw "Built artifact not found: $source"
    }

    $destination = $source
    if ($LocalBuild) {
      $destination = Get-LocalArtifactDestination (Get-Item -LiteralPath $source) $artifact $usedLocalNames
    }
    else {
      $destinationRelative = Get-OptionalProperty $artifact "destination"
      if ($destinationRelative) {
        $destination = Resolve-RepositoryPath (Expand-ConfigTokens ([string]$destinationRelative))
      }
    }
    if (-not $source.Equals($destination, [StringComparison]::OrdinalIgnoreCase)) {
      if ($LocalBuild) {
        Stop-ProcessesUsingLocalArtifacts @($destination)
      }
      $destinationDirectory = Split-Path -Parent $destination
      New-Item -ItemType Directory -Force -Path $destinationDirectory | Out-Null
      Copy-Item -LiteralPath $source -Destination $destination -Force
    }

    $file = Get-Item -LiteralPath $destination
    if ([bool](Get-OptionalProperty $artifact "verifyWindowsVersion" $false)) {
      if ($file.VersionInfo.FileVersion -ne $normalizedVersion) {
        throw "FileVersion mismatch for $destination`: $($file.VersionInfo.FileVersion)"
      }
      if ($file.VersionInfo.ProductVersion -ne $normalizedVersion) {
        throw "ProductVersion mismatch for $destination`: $($file.VersionInfo.ProductVersion)"
      }
    }

    $sha256 = $null
    if ([bool](Get-OptionalProperty $artifact "sha256" $true)) {
      $sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $destination).Hash
    }
    $results += [pscustomobject]@{
      Path = $destination
      Length = $file.Length
      SHA256 = $sha256
    }
  }
  return $results
}

function Write-ArtifactManifest($Artifacts) {
  if (-not $ArtifactManifestPath) { return }
  $path = if ([IO.Path]::IsPathRooted($ArtifactManifestPath)) {
    Get-NormalizedPath $ArtifactManifestPath
  }
  else {
    Get-NormalizedPath (Join-Path $script:ResolvedRepositoryRoot $ArtifactManifestPath)
  }
  $gitDirectory = Get-GitDirectory
  $gitPrefix = $gitDirectory + [IO.Path]::DirectorySeparatorChar
  if (-not $path.StartsWith($gitPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Artifact manifest must be stored inside the Git directory"
  }
  $directory = Split-Path -Parent $path
  New-Item -ItemType Directory -Force -Path $directory | Out-Null
  $records = @(
    @($Artifacts) | ForEach-Object {
      [pscustomobject][ordered]@{
        path = ConvertTo-RepositoryRelativePath ([string]$_.Path)
        sha256 = if ($_.SHA256) { [string]$_.SHA256 } else { (Get-FileHash -Algorithm SHA256 -LiteralPath $_.Path).Hash }
        length = [long]$_.Length
      }
    }
  )
  $manifest = [pscustomobject][ordered]@{
    schemaVersion = 1
    artifacts = $records
  }
  Write-Utf8NoBom $path (($manifest | ConvertTo-Json -Depth 10) + "`n")
}
