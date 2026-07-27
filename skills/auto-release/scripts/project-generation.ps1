# Internal version, build, asset, config, and workflow generation.

function New-VersionUpdate([string]$Path, [string]$Pattern, [string]$Replacement) {
  return [pscustomobject][ordered]@{
    path = $Path
    pattern = $Pattern
    replacement = $Replacement
    expectedMatches = 1
  }
}
function Add-ExistingVersionUpdate([ref]$Updates, [string]$RelativePath, [string]$Pattern, [string]$Replacement) {
  $path = Join-Path $script:ResolvedRepositoryRoot $RelativePath
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return }
  $count = ([regex]::new($Pattern)).Matches([IO.File]::ReadAllText($path)).Count
  if ($count -gt 1) { throw "Version pattern is ambiguous in ${RelativePath}: $count matches" }
  if ($count -eq 1) { $Updates.Value += New-VersionUpdate $RelativePath $Pattern $Replacement }
}

function Get-ReleaseNotesConfig {
  $heading =
    "## " +
    ([char]0x66F4).ToString() +
    ([char]0x65B0).ToString() +
    ([char]0x5185).ToString() +
    ([char]0x5BB9).ToString()
  return [pscustomobject][ordered]@{
    heading = $heading
    minItems = 2
    maxItems = 6
    requireChinese = $true
  }
}

function Get-WorkflowConfig {
  return [pscustomobject][ordered]@{
    name = "Release"
    event = "push"
    findTimeoutSeconds = 120
    waitTimeoutMinutes = 90
  }
}

function Get-RequiredAssets([string]$Type, [string]$Stem) {
  if ($Type -eq "node") {
    return @([pscustomobject][ordered]@{ pattern = "(?i)^$([regex]::Escape($Stem))-\d+\.\d+\.\d+\.tgz$"; label = "npm package" })
  }
  if ($Type -eq "go") {
    $names = @(
      "$Stem-windows-amd64.exe", "$Stem-windows-arm64.exe",
      "$Stem-linux-amd64", "$Stem-linux-arm64",
      "$Stem-darwin-amd64", "$Stem-darwin-arm64"
    )
    return @($names | ForEach-Object {
      [pscustomobject][ordered]@{ pattern = "(?i)^$([regex]::Escape($_))$"; label = $_ }
    })
  }
  if ($Type -eq "python") {
    return @(
      [pscustomobject][ordered]@{ pattern = '(?i)^.+-\d+\.\d+\.\d+\.tar\.gz$'; label = "Python source distribution" },
      [pscustomobject][ordered]@{ pattern = '(?i)^.+-\d+\.\d+\.\d+-.+\.whl$'; label = "Python wheel" }
    )
  }
  if ($Type -eq "rust") {
    return @([pscustomobject][ordered]@{ pattern = "(?i)^$([regex]::Escape($Stem))-\d+\.\d+\.\d+\.crate$"; label = "Rust crate" })
  }
  if ($Type -eq "dotnet") {
    return @([pscustomobject][ordered]@{ pattern = "(?i)^$([regex]::Escape($Stem))\.\d+\.\d+\.\d+\.nupkg$"; label = ".NET NuGet package" })
  }
  if ($Type -eq "java") {
    return @([pscustomobject][ordered]@{ pattern = "(?i)^$([regex]::Escape($Stem))-\d+\.\d+\.\d+(?:-[^/]+)?\.jar$"; label = "Java package" })
  }
  if ($Type -eq "cmake" -or $Type -eq "electron") {
    $names = @(
      "$Stem-windows-x64.zip", "$Stem-windows-arm64.zip",
      "$Stem-linux-x64.zip", "$Stem-linux-arm64.zip",
      "$Stem-macos-x64.zip", "$Stem-macos-arm64.zip"
    )
    return @($names | ForEach-Object { [pscustomobject][ordered]@{ pattern = "(?i)^$([regex]::Escape($_))$"; label = $_ } })
  }
  if ($Type -eq "flutter") {
    $names = @(
      "$Stem-android-apk.apk", "$Stem-android-aab.aab", "$Stem-windows-x64.zip",
      "$Stem-linux-x64.tar.gz", "$Stem-macos-x64.zip", "$Stem-macos-arm64.zip", "$Stem-web.zip"
    )
    return @($names | ForEach-Object { [pscustomobject][ordered]@{ pattern = "(?i)^$([regex]::Escape($_))$"; label = $_ } })
  }
  if ($Type -eq "android") {
    return @(
      [pscustomobject][ordered]@{ pattern = "(?i)^$([regex]::Escape($Stem))-\d+\.\d+\.\d+\.apk$"; label = "Android APK" },
      [pscustomobject][ordered]@{ pattern = "(?i)^$([regex]::Escape($Stem))-\d+\.\d+\.\d+\.aab$"; label = "Android App Bundle" }
    )
  }
  if ($Type -eq "docker") {
    return @([pscustomobject][ordered]@{ pattern = "(?i)^$([regex]::Escape($Stem))-\d+\.\d+\.\d+-image\.txt$"; label = "Container image manifest" })
  }
  return @(
    [pscustomobject][ordered]@{ pattern = '(?i)\.msi$'; label = "Windows MSI installer" },
    [pscustomobject][ordered]@{ pattern = '(?i)(?:setup|installer).*\.exe$'; label = "Windows executable installer" },
    [pscustomobject][ordered]@{ pattern = '(?i)(?:x64|x86_64).*\.dmg$'; label = "macOS Intel DMG" },
    [pscustomobject][ordered]@{ pattern = '(?i)(?:aarch64|arm64).*\.dmg$'; label = "macOS Apple Silicon DMG" },
    [pscustomobject][ordered]@{ pattern = '(?i)\.AppImage$'; label = "Linux AppImage" },
    [pscustomobject][ordered]@{ pattern = '(?i)\.(?:deb|rpm)$'; label = "Linux package" }
  )
}

function Get-ExpectedAssets($Profile, [string]$Stem) {
  if ($Profile.ProjectType -eq "node") { return @("$Stem-$($Profile.Version).tgz") }
  if ($Profile.ProjectType -eq "go") {
    return @(
      "$Stem-windows-amd64.exe", "$Stem-windows-arm64.exe",
      "$Stem-linux-amd64", "$Stem-linux-arm64",
      "$Stem-darwin-amd64", "$Stem-darwin-arm64"
    )
  }
  if ($Profile.ProjectType -eq "python") {
    $pythonStem = $Stem.Replace("-", "_")
    return @("$Stem-$($Profile.Version).tar.gz", "$pythonStem-$($Profile.Version)-py3-none-any.whl")
  }
  if ($Profile.ProjectType -eq "rust") { return @("$Stem-$($Profile.Version).crate") }
  if ($Profile.ProjectType -eq "dotnet") { return @("$Stem.$($Profile.Version).nupkg") }
  if ($Profile.ProjectType -eq "java") { return @("$Stem-$($Profile.Version).jar") }
  if ($Profile.ProjectType -eq "cmake" -or $Profile.ProjectType -eq "electron") {
    return @(
      "$Stem-windows-x64.zip", "$Stem-windows-arm64.zip",
      "$Stem-linux-x64.zip", "$Stem-linux-arm64.zip",
      "$Stem-macos-x64.zip", "$Stem-macos-arm64.zip"
    )
  }
  if ($Profile.ProjectType -eq "flutter") {
    return @(
      "$Stem-android-apk.apk", "$Stem-android-aab.aab", "$Stem-windows-x64.zip",
      "$Stem-linux-x64.tar.gz", "$Stem-macos-x64.zip", "$Stem-macos-arm64.zip", "$Stem-web.zip"
    )
  }
  if ($Profile.ProjectType -eq "android") { return @("$Stem-$($Profile.Version).apk", "$Stem-$($Profile.Version).aab") }
  if ($Profile.ProjectType -eq "docker") { return @("$Stem-$($Profile.Version)-image.txt") }
  return @(
    "${Stem}_$($Profile.Version)_x64_en-US.msi",
    "${Stem}_$($Profile.Version)_x64-setup.exe",
    "${Stem}_$($Profile.Version)_x64.dmg",
    "${Stem}_$($Profile.Version)_aarch64.dmg",
    "${Stem}_$($Profile.Version)_amd64.AppImage",
    "${Stem}_$($Profile.Version)_amd64.deb"
  )
}

function New-GenerationBundle(
  $Profile,
  [string]$SelectedWorkflowPath = $WorkflowPath,
  [bool]$ManagedWorkflow = $true
) {
  $defaults = Get-RepositoryDefaults
  $stem = ConvertTo-ArtifactStem $Profile.ProjectName
  $updates = @()
  $bootstrapCommands = @()
  $bootstrapInputs = @()
  $bootstrapRequiredPaths = @()
  $localCommands = $null
  $commands = @()
  $artifacts = @()
  $localArtifacts = $null
  $localSearchRoots = @()
  $additionalFiles = @()
  $readPath = $Profile.VersionSource
  $readPattern = $null

  if ($Profile.ProjectType -eq "node") {
    $readPattern = '"version"\s*:\s*"(?<version>\d+\.\d+\.\d+)"'
    $updates += New-VersionUpdate "package.json" '("version"\s*:\s*")\d+\.\d+\.\d+(")' '${1}{version}$2'
    Add-ExistingVersionUpdate ([ref]$updates) "package-lock.json" '(?ms)\A(\s*\{.{0,1000}?"version"\s*:\s*")\d+\.\d+\.\d+(")' '${1}{version}$2'
    Add-ExistingVersionUpdate ([ref]$updates) "package-lock.json" '(?ms)(""\s*:\s*\{[^{}]*?"version"\s*:\s*")\d+\.\d+\.\d+(")' '${1}{version}$2'
    $bootstrapCommands += [pscustomobject][ordered]@{ name = "Install dependencies"; command = $Profile.Manager.Install }
    $bootstrapInputs += @("package.json", "package-lock.json", "pnpm-lock.yaml", "yarn.lock", "bun.lock", "bun.lockb") | Where-Object {
      Test-Path -LiteralPath (Join-Path $script:ResolvedRepositoryRoot $_)
    }
    $bootstrapRequiredPaths += "node_modules"
    if (Test-PackageScript $Profile.Package "test") {
      $commands += [pscustomobject][ordered]@{ name = "Tests"; command = Get-PackageCommand $Profile.Manager.Name "test" }
    }
    if (Test-PackageScript $Profile.Package "build") {
      $commands += [pscustomobject][ordered]@{ name = "Build"; command = Get-PackageCommand $Profile.Manager.Name "build" }
    }
    $commands += [pscustomobject][ordered]@{ name = "Pack"; command = "if not exist dist mkdir dist && npm pack --pack-destination dist" }
    $artifacts += [pscustomobject][ordered]@{ source = "dist/$Stem-{version}.tgz"; sha256 = $true }
  }
  elseif ($Profile.ProjectType -eq "electron") {
    $readPattern = '"version"\s*:\s*"(?<version>\d+\.\d+\.\d+)"'
    $updates += New-VersionUpdate "package.json" '("version"\s*:\s*")\d+\.\d+\.\d+(")' '${1}{version}$2'
    Add-ExistingVersionUpdate ([ref]$updates) "package-lock.json" '(?ms)\A(\s*\{.{0,1000}?"version"\s*:\s*")\d+\.\d+\.\d+(")' '${1}{version}$2'
    Add-ExistingVersionUpdate ([ref]$updates) "package-lock.json" '(?ms)(""\s*:\s*\{[^{}]*?"version"\s*:\s*")\d+\.\d+\.\d+(")' '${1}{version}$2'
    $bootstrapCommands += [pscustomobject][ordered]@{ name = "Install dependencies"; command = $Profile.Manager.Install }
    $bootstrapInputs += @("package.json", "package-lock.json", "pnpm-lock.yaml", "yarn.lock", "bun.lock", "bun.lockb") | Where-Object {
      Test-Path -LiteralPath (Join-Path $script:ResolvedRepositoryRoot $_)
    }
    $bootstrapRequiredPaths += "node_modules"
    if (Test-PackageScript $Profile.Package "test") {
      $commands += [pscustomobject][ordered]@{ name = "Tests"; command = Get-PackageCommand $Profile.Manager.Name "test" }
    }
    $commands += [pscustomobject][ordered]@{ name = "Build Electron packages"; command = $Profile.ElectronBuildCommand }
    $localCommands = @($commands)
    $localArtifacts = @()
    $localSearchRoots += $Profile.ElectronOutput
  }
  elseif ($Profile.ProjectType -eq "tauri") {
    $readPattern = '"version"\s*:\s*"(?<version>\d+\.\d+\.\d+)"'
    Add-ExistingVersionUpdate ([ref]$updates) "src-tauri/tauri.conf.json" '("version"\s*:\s*")\d+\.\d+\.\d+(")' '${1}{version}$2'
    Add-ExistingVersionUpdate ([ref]$updates) "package.json" '("version"\s*:\s*")\d+\.\d+\.\d+(")' '${1}{version}$2'
    Add-ExistingVersionUpdate ([ref]$updates) "package-lock.json" '(?ms)\A(\s*\{.{0,1000}?"version"\s*:\s*")\d+\.\d+\.\d+(")' '${1}{version}$2'
    Add-ExistingVersionUpdate ([ref]$updates) "package-lock.json" '(?ms)(""\s*:\s*\{[^{}]*?"version"\s*:\s*")\d+\.\d+\.\d+(")' '${1}{version}$2'
    $cargoPattern = '(?ms)(^\[package\]\s*(?:(?!^\[).)*?^version\s*=\s*")\d+\.\d+\.\d+(")'
    Add-ExistingVersionUpdate ([ref]$updates) "src-tauri/Cargo.toml" $cargoPattern '${1}{version}$2'
    $cargoText = [IO.File]::ReadAllText((Join-Path $script:ResolvedRepositoryRoot "src-tauri\Cargo.toml"))
    $cargoNameMatch = [regex]::Match($cargoText, '(?ms)^\[package\]\s*(?:(?!^\[).)*?^name\s*=\s*"(?<name>[^"]+)"')
    if ($cargoNameMatch.Success) {
      $cargoName = [regex]::Escape($cargoNameMatch.Groups["name"].Value)
      $lockPattern = '(?ms)(^\[\[package\]\]\s*(?:(?!^\[\[package\]\]).)*?^name\s*=\s*"' + $cargoName + '"\s*(?:(?!^\[\[package\]\]).)*?^version\s*=\s*")\d+\.\d+\.\d+(")'
      Add-ExistingVersionUpdate ([ref]$updates) "src-tauri/Cargo.lock" $lockPattern '${1}{version}$2'
    }
    if ($Profile.Package) {
      $bootstrapCommands += [pscustomobject][ordered]@{ name = "Install dependencies"; command = $Profile.Manager.Install }
      $bootstrapInputs += @("package.json", "package-lock.json", "pnpm-lock.yaml", "yarn.lock", "bun.lock", "bun.lockb", "src-tauri/Cargo.toml", "src-tauri/Cargo.lock") | Where-Object {
        Test-Path -LiteralPath (Join-Path $script:ResolvedRepositoryRoot $_)
      }
      $bootstrapRequiredPaths += "node_modules"
      if (Test-PackageScript $Profile.Package "test") {
        $commands += [pscustomobject][ordered]@{ name = "Tests"; command = Get-PackageCommand $Profile.Manager.Name "test" }
      }
      $commands += [pscustomobject][ordered]@{ name = "Build installers"; command = Get-PackageCommand $Profile.Manager.Name "tauri build" }
      $localCommands = @($commands | Where-Object { $_.name -ne "Build installers" })
      $localCommands += [pscustomobject][ordered]@{ name = "Build local program"; command = Get-TauriLocalBuildCommand $Profile.Manager.Name }
    }
    else {
      $commands += [pscustomobject][ordered]@{ name = "Build installers"; command = "cargo tauri build" }
      $localCommands = @([pscustomobject][ordered]@{ name = "Build local program"; command = "cargo tauri build --no-bundle" })
      $bootstrapInputs += @("src-tauri/Cargo.toml", "src-tauri/Cargo.lock") | Where-Object {
        Test-Path -LiteralPath (Join-Path $script:ResolvedRepositoryRoot $_)
      }
    }
  }
  elseif ($Profile.ProjectType -eq "go") {
    $readPattern = '(?m)^(?<version>\d+\.\d+\.\d+)\s*$'
    $updates += New-VersionUpdate "VERSION" '(?m)^\d+\.\d+\.\d+\s*$' '{version}'
    if ($Profile.NeedsVersionFile) {
      $additionalFiles += [pscustomobject]@{ RelativePath = "VERSION"; Content = "$($Profile.Version)`n" }
    }
    $commands += [pscustomobject][ordered]@{ name = "Tests"; command = "go test ./..." }
    $commands += [pscustomobject][ordered]@{ name = "Build Windows"; command = "if not exist dist mkdir dist && go build -trimpath -o dist\$Stem.exe $($Profile.BuildPath)" }
    $artifacts += [pscustomobject][ordered]@{ source = "dist/$Stem.exe"; sha256 = $true }
  }
  elseif ($Profile.ProjectType -eq "flutter") {
    $readPattern = $Profile.VersionReadPattern
    $updates += New-VersionUpdate $Profile.VersionSource $Profile.VersionUpdatePattern '${1}{version}'
    $bootstrapCommands += [pscustomobject][ordered]@{ name = "Install dependencies"; command = "flutter pub get" }
    $bootstrapInputs += @("pubspec.yaml", "pubspec.lock") | Where-Object {
      Test-Path -LiteralPath (Join-Path $script:ResolvedRepositoryRoot $_)
    }
    $bootstrapRequiredPaths += ".dart_tool/package_config.json"
    if ($Profile.HasTests) { $commands += [pscustomobject][ordered]@{ name = "Tests"; command = "flutter test" } }
    $commands += [pscustomobject][ordered]@{ name = "Build Windows"; command = "flutter build windows --release" }
  }
  elseif ($Profile.ProjectType -eq "android") {
    $readPattern = $Profile.VersionReadPattern
    $updates += New-VersionUpdate $Profile.VersionSource $Profile.VersionUpdatePattern '${1}{version}$2'
    $commands += [pscustomobject][ordered]@{ name = "Test and package Android"; command = $Profile.AndroidLocalBuild }
  }
  elseif ($Profile.ProjectType -eq "cmake") {
    if ($Profile.NeedsVersionFile) {
      $readPattern = '(?m)^(?<version>\d+\.\d+\.\d+)\s*$'
      $updates += New-VersionUpdate "VERSION" '(?m)^\d+\.\d+\.\d+\s*$' '{version}'
      $additionalFiles += [pscustomobject]@{ RelativePath = "VERSION"; Content = "$($Profile.Version)`n" }
    }
    else {
      $projectName = [regex]::Escape($Profile.ProjectName)
      $readPattern = '(?is)\bproject\s*\(\s*' + $projectName + '(?:(?!\)).)*?\bVERSION\s+(?<version>\d+\.\d+\.\d+)'
      $updatePattern = '(?is)(\bproject\s*\(\s*' + $projectName + '(?:(?!\)).)*?\bVERSION\s+)\d+\.\d+\.\d+'
      $updates += New-VersionUpdate "CMakeLists.txt" $updatePattern '${1}{version}'
    }
    $commands += [pscustomobject][ordered]@{ name = "Configure"; command = "cmake -S . -B build -DCMAKE_BUILD_TYPE=Release" }
    $commands += [pscustomobject][ordered]@{ name = "Build"; command = "cmake --build build --config Release --parallel" }
    $commands += [pscustomobject][ordered]@{ name = "Tests"; command = "ctest --test-dir build -C Release --output-on-failure" }
  }
  elseif ($Profile.ProjectType -eq "docker") {
    $readPattern = '(?m)^(?<version>\d+\.\d+\.\d+)\s*$'
    $updates += New-VersionUpdate "VERSION" '(?m)^\d+\.\d+\.\d+\s*$' '{version}'
    if ($Profile.NeedsVersionFile) {
      $additionalFiles += [pscustomobject]@{ RelativePath = "VERSION"; Content = "$($Profile.Version)`n" }
    }
    $commands += [pscustomobject][ordered]@{ name = "Build container"; command = "docker build --file `"$($Profile.BuildPath)`" --tag `"${Stem}:{version}`" ." }
  }
  elseif ($Profile.ProjectType -eq "python") {
    $readPattern = $Profile.VersionReadPattern
    $updates += New-VersionUpdate $Profile.VersionSource $Profile.VersionUpdatePattern '${1}{version}$2'
    if ($Profile.PackageManager -eq "uv") {
      $bootstrapCommands += [pscustomobject][ordered]@{ name = "Install dependencies"; command = "python -m pip install uv && uv sync --all-extras" }
      if ($Profile.HasTests) { $commands += [pscustomobject][ordered]@{ name = "Tests"; command = "uv run pytest" } }
      $commands += [pscustomobject][ordered]@{ name = "Build distributions"; command = "uv build" }
      $localCommands = @($commands | Where-Object { $_.name -ne "Build distributions" })
      $localCommands += [pscustomobject][ordered]@{ name = "Build local wheel"; command = "uv build --wheel" }
    }
    elseif ($Profile.PackageManager -eq "poetry") {
      $bootstrapCommands += [pscustomobject][ordered]@{ name = "Install dependencies"; command = "python -m pip install poetry && poetry install" }
      if ($Profile.HasTests) { $commands += [pscustomobject][ordered]@{ name = "Tests"; command = "poetry run pytest" } }
      $commands += [pscustomobject][ordered]@{ name = "Build distributions"; command = "poetry build" }
      $localCommands = @($commands | Where-Object { $_.name -ne "Build distributions" })
      $localCommands += [pscustomobject][ordered]@{ name = "Build local wheel"; command = "poetry build -f wheel" }
    }
    else {
      $installCommand = "python -m pip install --upgrade build && python -m pip install -e ."
      if ($Profile.HasTests) { $installCommand += " && python -m pip install pytest" }
      $bootstrapCommands += [pscustomobject][ordered]@{ name = "Install dependencies"; command = $installCommand }
      if ($Profile.HasTests) { $commands += [pscustomobject][ordered]@{ name = "Tests"; command = "python -m pytest" } }
      $commands += [pscustomobject][ordered]@{ name = "Build distributions"; command = "python -m build" }
      $localCommands = @($commands | Where-Object { $_.name -ne "Build distributions" })
      $localCommands += [pscustomobject][ordered]@{ name = "Build local wheel"; command = "python -m build --wheel" }
    }
    $bootstrapInputs += @("pyproject.toml", "uv.lock", "poetry.lock", "requirements.txt") | Where-Object {
      Test-Path -LiteralPath (Join-Path $script:ResolvedRepositoryRoot $_)
    }
    $localArtifacts = @()
  }
  elseif ($Profile.ProjectType -eq "rust") {
    $readPattern = '(?ms)^\[package\]\s*(?:(?!^\[).)*?^version\s*=\s*"(?<version>\d+\.\d+\.\d+)"'
    $cargoPattern = '(?ms)(^\[package\]\s*(?:(?!^\[).)*?^version\s*=\s*")\d+\.\d+\.\d+(")'
    $updates += New-VersionUpdate "Cargo.toml" $cargoPattern '${1}{version}$2'
    $cargoName = [regex]::Escape($Profile.ProjectName)
    $lockPattern = '(?ms)(^\[\[package\]\]\s*(?:(?!^\[\[package\]\]).)*?^name\s*=\s*"' + $cargoName + '"\s*(?:(?!^\[\[package\]\]).)*?^version\s*=\s*")\d+\.\d+\.\d+(")'
    Add-ExistingVersionUpdate ([ref]$updates) "Cargo.lock" $lockPattern '${1}{version}$2'
    $commands += [pscustomobject][ordered]@{ name = "Tests"; command = "cargo test --all" }
    $commands += [pscustomobject][ordered]@{ name = "Package crate"; command = "cargo package --allow-dirty" }
    $localCommands = @(
      [pscustomobject][ordered]@{ name = "Tests"; command = "cargo test --all" },
      [pscustomobject][ordered]@{ name = "Build local target"; command = "cargo build --release" }
    )
    $localArtifacts = @()
    $artifacts += [pscustomobject][ordered]@{ source = "target/package/$Stem-{version}.crate"; sha256 = $true }
  }
  elseif ($Profile.ProjectType -eq "dotnet") {
    if ($Profile.NeedsVersionFile) {
      $readPattern = '(?m)^(?<version>\d+\.\d+\.\d+)\s*$'
      $updates += New-VersionUpdate "VERSION" '(?m)^\d+\.\d+\.\d+\s*$' '{version}'
      $additionalFiles += [pscustomobject]@{ RelativePath = "VERSION"; Content = "$($Profile.Version)`n" }
    }
    else {
      $element = [regex]::Escape([string]$Profile.VersionElement)
      $readPattern = "(?s)<$element>\s*(?<version>\d+\.\d+\.\d+)\s*</$element>"
      $updatePattern = "(?s)(<$element>\s*)\d+\.\d+\.\d+(\s*</$element>)"
      $updates += New-VersionUpdate $Profile.VersionSource $updatePattern '${1}{version}$2'
    }
    $bootstrapCommands += [pscustomobject][ordered]@{ name = "Restore"; command = "dotnet restore `"$($Profile.BuildPath)`"" }
    $bootstrapInputs += @($Profile.BuildPath, "packages.lock.json") | Where-Object {
      Test-Path -LiteralPath (Join-Path $script:ResolvedRepositoryRoot $_)
    }
    $projectDirectory = Split-Path -Parent $Profile.BuildPath
    $bootstrapRequiredPaths += if ($projectDirectory) { "$projectDirectory/obj/project.assets.json" } else { "obj/project.assets.json" }
    $commands += [pscustomobject][ordered]@{ name = "Tests"; command = "dotnet test `"$($Profile.BuildPath)`" --no-restore --configuration Release" }
    $commands += [pscustomobject][ordered]@{ name = "Pack"; command = "dotnet pack `"$($Profile.BuildPath)`" --no-restore --configuration Release -p:PackageVersion={version} --output dist" }
    $localCommands = @(
      [pscustomobject][ordered]@{ name = "Tests"; command = "dotnet test `"$($Profile.BuildPath)`" --no-restore --configuration Release" },
      [pscustomobject][ordered]@{ name = "Build local target"; command = "dotnet build `"$($Profile.BuildPath)`" --no-restore --configuration Release" }
    )
    $localArtifacts = @()
    $localSearchRoots += if ($projectDirectory) { "$projectDirectory/bin/Release" } else { "bin/Release" }
    $artifacts += [pscustomobject][ordered]@{ source = "dist/$Stem.{version}.nupkg"; sha256 = $true }
  }
  elseif ($Profile.ProjectType -eq "java") {
    $readPattern = $Profile.VersionReadPattern
    $updates += New-VersionUpdate $Profile.VersionSource $Profile.VersionUpdatePattern '${1}{version}$2'
    $commands += [pscustomobject][ordered]@{ name = "Test and package"; command = $Profile.JavaLocalBuild }
  }
  else {
    throw "No generation strategy for project type: $($Profile.ProjectType)"
  }

  if ($null -eq $localCommands) { $localCommands = @($commands) }
  if ($null -eq $localArtifacts) { $localArtifacts = @($artifacts) }

  $templateName = "$($Profile.ProjectType)-v1"
  $requiredAssets = @(Get-RequiredAssets $Profile.ProjectType $stem)
  $config = [pscustomobject][ordered]@{
    schemaVersion = 2
    projectType = $Profile.ProjectType
    automation = [pscustomobject][ordered]@{
      generator = $script:GeneratorName
      template = $templateName
      managedWorkflow = $ManagedWorkflow
      workflowFile = $SelectedWorkflowPath.Replace("\", "/")
    }
    projectName = $Profile.ProjectName
    branch = $defaults.Branch
    remote = $defaults.Remote
    tagPrefix = "v"
    commit = [pscustomobject][ordered]@{
      policy = "auto"
      analyzeCount = 30
      minimumSamples = 3
      confidenceThreshold = 0.6
      fallback = "conventional"
    }
    version = [pscustomobject][ordered]@{
      read = [pscustomobject][ordered]@{ path = $readPath; pattern = $readPattern }
      updates = @($updates)
    }
    prepare = [pscustomobject][ordered]@{
      parallel = $false
      localOutputDirectory = "output"
      bootstrapInputs = @($bootstrapInputs | Sort-Object -Unique)
      bootstrapRequiredPaths = @($bootstrapRequiredPaths | Sort-Object -Unique)
      bootstrapCommands = @($bootstrapCommands)
      localCommands = @($localCommands)
      commands = @($commands)
      localArtifacts = @($localArtifacts)
      localSearchRoots = @($localSearchRoots | Sort-Object -Unique)
      artifacts = @($artifacts)
    }
    releaseNotes = Get-ReleaseNotesConfig
    publish = [pscustomobject][ordered]@{
      workflow = Get-WorkflowConfig
      release = [pscustomobject][ordered]@{
        mode = "publish-draft"
        title = "{projectName} {tag}"
        requireDraft = $true
        requiredAssets = $requiredAssets
      }
    }
  }

  $expectedAssets = @(Get-ExpectedAssets $Profile $stem)
  $testStep = ""
  $buildStep = ""
  $managerSetup = ""
  $installCommand = "echo No package.json; skipping frontend dependencies"
  $pythonInstallCommand = "python -m pip install --upgrade build && python -m pip install -e ."
  $pythonBuildCommand = "python -m build"
  if ($Profile.Package) {
    $managerSetup = $Profile.Manager.WorkflowSetup
    $installCommand = $Profile.Manager.Install
    if (Test-PackageScript $Profile.Package "test") {
      $testStep = "      - name: Test`n        run: $(Get-PackageCommand $Profile.Manager.Name 'test')"
    }
    if (Test-PackageScript $Profile.Package "build") {
      $buildStep = "      - name: Build`n        run: $(Get-PackageCommand $Profile.Manager.Name 'build')"
    }
  }
  if ($Profile.ProjectType -eq "python") {
    if ($Profile.PackageManager -eq "uv") {
      $pythonInstallCommand = "python -m pip install uv && uv sync --all-extras"
      $pythonBuildCommand = "uv build"
      if ($Profile.HasTests) { $testStep = "      - name: Test`n        run: uv run pytest" }
    }
    elseif ($Profile.PackageManager -eq "poetry") {
      $pythonInstallCommand = "python -m pip install poetry && poetry install"
      $pythonBuildCommand = "poetry build"
      if ($Profile.HasTests) { $testStep = "      - name: Test`n        run: poetry run pytest" }
    }
    elseif ($Profile.HasTests) {
      $testStep = "      - name: Test`n        run: python -m pip install pytest && python -m pytest"
    }
  }
  $tokens = @{
    PROJECT_NAME = $Profile.ProjectName.Replace('"', '')
    ARTIFACT_STEM = $stem
    BUILD_PATH = [string]$Profile.BuildPath
    PACKAGE_MANAGER_SETUP = $managerSetup
    INSTALL_COMMAND = $installCommand
    TEST_STEP = $testStep
    BUILD_STEP = $buildStep
    PYTHON_INSTALL_COMMAND = $pythonInstallCommand
    PYTHON_BUILD_COMMAND = $pythonBuildCommand
    DOTNET_PROJECT = [string]$Profile.BuildPath
    DOTNET_VERSION = [string](Get-OptionalProperty $Profile "DotNetVersion" "8.0.x")
    JAVA_CACHE = [string](Get-OptionalProperty $Profile "JavaCache" "maven")
    JAVA_BUILD_COMMAND = [string](Get-OptionalProperty $Profile "JavaWorkflowBuild" "mvn -B test package")
    JAVA_ARTIFACT_DIRECTORY = [string](Get-OptionalProperty $Profile "JavaArtifactDirectory" "target")
    CMAKE_TARGET = [string](Get-OptionalProperty $Profile "CMakeTarget" "app")
    ANDROID_MODULE = [string]$Profile.BuildPath
    ELECTRON_BUILD_COMMAND = [string](Get-OptionalProperty $Profile "ElectronBuildCommand" "npm run dist")
    ELECTRON_OUTPUT = [string](Get-OptionalProperty $Profile "ElectronOutput" "dist")
    DOCKERFILE = [string]$Profile.BuildPath
    EXPECTED_ASSET = $expectedAssets[0]
    EXPECTED_ASSET_COMMENTS = (($expectedAssets | ForEach-Object { "# Expected asset: $_" }) -join "`n")
  }
  return [pscustomobject]@{
    Config = $config
    TemplateName = $templateName
    TemplateFile = Join-Path (Split-Path -Parent $PSScriptRoot) "assets\workflows\$($Profile.ProjectType).yml"
    Tokens = $tokens
    AdditionalFiles = @($additionalFiles)
  }
}
