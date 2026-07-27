# Internal project detection and profile construction.

function Get-RepositoryDefaults {
  $branch = Get-GitValue @("branch", "--show-current")
  if (-not $branch) { $branch = "main" }
  $remotes = @((Get-GitValue @("remote")) -split "`r?`n" | Where-Object { $_ })
  $remote = if ($remotes -contains "origin") { "origin" } elseif ($remotes.Count -gt 0) { $remotes[0] } else { "origin" }
  return [pscustomobject]@{ Branch = $branch; Remote = $remote }
}
function Get-PackageManager {
  $name = "npm"
  $install = "npm install"
  $setup = ""
  if (Test-Path -LiteralPath (Join-Path $script:ResolvedRepositoryRoot "pnpm-lock.yaml")) {
    $name = "pnpm"
    $install = "pnpm install --frozen-lockfile"
    $setup = "      - name: Enable Corepack`n        run: corepack enable"
  }
  elseif (Test-Path -LiteralPath (Join-Path $script:ResolvedRepositoryRoot "yarn.lock")) {
    $name = "yarn"
    $install = "yarn install --frozen-lockfile"
    $setup = "      - name: Enable Corepack`n        run: corepack enable"
  }
  elseif (
    (Test-Path -LiteralPath (Join-Path $script:ResolvedRepositoryRoot "bun.lock")) -or
    (Test-Path -LiteralPath (Join-Path $script:ResolvedRepositoryRoot "bun.lockb"))
  ) {
    $name = "bun"
    $install = "bun install --frozen-lockfile"
    $setup = "      - uses: oven-sh/setup-bun@0c5077e51419868618aeaa5fe8019c62421857d6 # v2"
  }
  elseif (Test-Path -LiteralPath (Join-Path $script:ResolvedRepositoryRoot "package-lock.json")) {
    $install = "npm ci"
  }
  return [pscustomobject]@{ Name = $name; Install = $install; WorkflowSetup = $setup }
}

function Get-PackageCommand([string]$Manager, [string]$ScriptName) {
  if ($Manager -eq "npm") { return "npm run $ScriptName" }
  if ($Manager -eq "pnpm") { return "pnpm run $ScriptName" }
  if ($Manager -eq "yarn") { return "yarn $ScriptName" }
  return "bun run $ScriptName"
}

function Get-TauriLocalBuildCommand([string]$Manager) {
  $command = Get-PackageCommand $Manager "tauri build"
  if ($Manager -in @("npm", "pnpm")) { return "$command -- --no-bundle" }
  return "$command --no-bundle"
}

function Test-PackageScript($Package, [string]$Name) {
  $scripts = Get-OptionalProperty $Package "scripts"
  $value = [string](Get-OptionalProperty $scripts $Name "")
  if (-not $value) { return $false }
  if ($Name -eq "test" -and $value -match "no test specified") { return $false }
  return $true
}

function ConvertTo-ArtifactStem([string]$Name) {
  $stem = $Name.ToLowerInvariant() -replace '^@', '' -replace '[\\/]+', '-' -replace '[^a-z0-9._-]+', '-'
  $stem = $stem.Trim('-', '.')
  if (-not $stem) { return "release" }
  return $stem
}

function Get-InferredVersion {
  $versionFile = Join-Path $script:ResolvedRepositoryRoot "VERSION"
  if (Test-Path -LiteralPath $versionFile -PathType Leaf) {
    $value = ([IO.File]::ReadAllText($versionFile)).Trim()
    if ($value -notmatch '^\d+\.\d+\.\d+$') {
      throw "VERSION must contain a stable semantic version"
    }
    return $value
  }
  $tags = @(Get-GitValue @("tag", "--list", "v[0-9]*", "--sort=-v:refname") -split "`r?`n")
  foreach ($tag in $tags) {
    if ($tag -match '^v(?<version>\d+\.\d+\.\d+)$') { return $Matches.version }
  }
  return "0.1.0"
}

function Get-RelativeRepositoryPath([string]$Path) {
  $fullPath = Get-NormalizedPath $Path
  $prefix = $script:ResolvedRepositoryRoot + [IO.Path]::DirectorySeparatorChar
  if (-not $fullPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Path is outside repository root: $Path"
  }
  return $fullPath.Substring($prefix.Length).Replace("\", "/")
}

function Get-XmlDirectValue($Document, [string]$Name) {
  $node = @($Document.DocumentElement.ChildNodes | Where-Object { $_.LocalName -eq $Name }) | Select-Object -First 1
  if ($node) { return [string]$node.InnerText }
  return $null
}

function Get-XmlDescendantValue($Document, [string]$Name) {
  $node = $Document.SelectSingleNode("//*[local-name()='$Name']")
  if ($node) { return [string]$node.InnerText }
  return $null
}

function Get-DotNetProjectFiles {
  $files = @()
  $excluded = @(".git", ".venv", "bin", "build", "dist", "node_modules", "obj", "target", "vendor", "venv")
  $queue = New-Object 'Collections.Generic.Queue[string]'
  $queue.Enqueue($script:ResolvedRepositoryRoot)
  while ($queue.Count -gt 0) {
    $directory = $queue.Dequeue()
    foreach ($file in Get-ChildItem -LiteralPath $directory -File) {
      if ($file.Extension -in @(".csproj", ".fsproj", ".vbproj")) { $files += $file }
    }
    foreach ($child in Get-ChildItem -LiteralPath $directory -Directory) {
      if ($child.Name -notin $excluded -and -not ($child.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        $queue.Enqueue($child.FullName)
      }
    }
  }
  return @($files)
}

function Get-AndroidApplicationModules {
  $modules = @()
  foreach ($directory in Get-ChildItem -LiteralPath $script:ResolvedRepositoryRoot -Directory) {
    foreach ($name in @("build.gradle.kts", "build.gradle")) {
      $candidate = Join-Path $directory.FullName $name
      if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        $content = [IO.File]::ReadAllText($candidate)
        if ($content -match 'com\.android\.application') {
          $modules += [pscustomobject]@{
            Directory = Get-RelativeRepositoryPath $directory.FullName
            BuildFile = Get-RelativeRepositoryPath $candidate
            Content = $content
          }
        }
      }
    }
  }
  return @($modules)
}

function Test-ElectronPackage($Package) {
  if (-not $Package) { return $false }
  $dependencies = Get-OptionalProperty $Package "dependencies"
  $devDependencies = Get-OptionalProperty $Package "devDependencies"
  return $null -ne (Get-OptionalProperty $dependencies "electron") -or
    $null -ne (Get-OptionalProperty $devDependencies "electron")
}

function Get-ProjectProfile([string]$RequestedType) {
  $tauriConfigPath = Join-Path $script:ResolvedRepositoryRoot "src-tauri\tauri.conf.json"
  $tauriCargoPath = Join-Path $script:ResolvedRepositoryRoot "src-tauri\Cargo.toml"
  $packagePath = Join-Path $script:ResolvedRepositoryRoot "package.json"
  $goModPath = Join-Path $script:ResolvedRepositoryRoot "go.mod"
  $pythonPath = Join-Path $script:ResolvedRepositoryRoot "pyproject.toml"
  $cargoPath = Join-Path $script:ResolvedRepositoryRoot "Cargo.toml"
  $mavenPath = Join-Path $script:ResolvedRepositoryRoot "pom.xml"
  $gradlePath = Join-Path $script:ResolvedRepositoryRoot "build.gradle"
  $gradleKtsPath = Join-Path $script:ResolvedRepositoryRoot "build.gradle.kts"
  $flutterPath = Join-Path $script:ResolvedRepositoryRoot "pubspec.yaml"
  $cmakePath = Join-Path $script:ResolvedRepositoryRoot "CMakeLists.txt"
  $dockerPath = Join-Path $script:ResolvedRepositoryRoot "Dockerfile"
  $hasTauri = (Test-Path -LiteralPath $tauriConfigPath -PathType Leaf) -and (Test-Path -LiteralPath $tauriCargoPath -PathType Leaf)
  $hasNode = Test-Path -LiteralPath $packagePath -PathType Leaf
  $packageManifest = if ($hasNode) { Read-JsonFile $packagePath "package.json" } else { $null }
  $hasElectron = Test-ElectronPackage $packageManifest
  $hasGo = Test-Path -LiteralPath $goModPath -PathType Leaf
  $hasPython = Test-Path -LiteralPath $pythonPath -PathType Leaf
  $hasRust = Test-Path -LiteralPath $cargoPath -PathType Leaf
  $dotnetProjects = @(Get-DotNetProjectFiles)
  $dotnetProject = if ($dotnetProjects.Count -eq 1) { $dotnetProjects[0] } else { $null }
  $hasDotNet = $dotnetProjects.Count -gt 0
  $hasJava = (Test-Path -LiteralPath $mavenPath -PathType Leaf) -or
    (Test-Path -LiteralPath $gradlePath -PathType Leaf) -or
    (Test-Path -LiteralPath $gradleKtsPath -PathType Leaf)
  $androidModules = @(Get-AndroidApplicationModules)
  $hasGradleWrapper = Test-Path -LiteralPath (Join-Path $script:ResolvedRepositoryRoot "gradlew") -PathType Leaf
  $hasAndroid = $androidModules.Count -gt 0 -and $hasGradleWrapper
  $hasFlutter = Test-Path -LiteralPath $flutterPath -PathType Leaf
  $hasCMake = Test-Path -LiteralPath $cmakePath -PathType Leaf
  $hasDocker = Test-Path -LiteralPath $dockerPath -PathType Leaf

  $detectedType = $RequestedType
  if ($RequestedType -eq "auto") {
    if ($hasTauri) { $detectedType = "tauri" }
    elseif ($hasFlutter) { $detectedType = "flutter" }
    elseif ($hasAndroid) { $detectedType = "android" }
    elseif ($hasElectron) { $detectedType = "electron" }
    else {
      $candidates = @()
      if ($hasNode -and -not $hasElectron) { $candidates += "node" }
      if ($hasGo) { $candidates += "go" }
      if ($hasPython) { $candidates += "python" }
      if ($hasRust) { $candidates += "rust" }
      if ($hasDotNet) { $candidates += "dotnet" }
      if ($hasJava) { $candidates += "java" }
      if ($hasCMake) { $candidates += "cmake" }
      if ($hasDocker -and $candidates.Count -eq 0) { $candidates += "docker" }
      if ($candidates.Count -gt 1) {
        throw "Project detection is ambiguous: $($candidates -join ', '); use -ProjectType explicitly"
      }
      if ($candidates.Count -eq 0) {
        throw "Unsupported project: no supported release manifest was found"
      }
      $detectedType = $candidates[0]
    }
  }
  if ($detectedType -eq "tauri" -and -not $hasTauri) { throw "Tauri detection requires src-tauri/tauri.conf.json and src-tauri/Cargo.toml" }
  if ($detectedType -eq "node" -and -not $hasNode) { throw "Node.js detection requires package.json" }
  if ($detectedType -eq "go" -and -not $hasGo) { throw "Go detection requires go.mod" }
  if ($detectedType -eq "python" -and -not $hasPython) { throw "Python detection requires pyproject.toml" }
  if ($detectedType -eq "rust" -and -not $hasRust) { throw "Rust detection requires Cargo.toml" }
  if ($detectedType -eq "dotnet" -and $dotnetProjects.Count -ne 1) { throw ".NET detection requires exactly one project file" }
  if ($detectedType -eq "java" -and -not $hasJava) { throw "Java detection requires pom.xml or build.gradle" }
  if ($detectedType -eq "cmake" -and -not $hasCMake) { throw "CMake detection requires CMakeLists.txt" }
  if ($detectedType -eq "flutter" -and -not $hasFlutter) { throw "Flutter detection requires pubspec.yaml" }
  if ($detectedType -eq "android" -and ($androidModules.Count -ne 1 -or -not $hasGradleWrapper)) { throw "Android detection requires one application module and the Gradle wrapper" }
  if ($detectedType -eq "electron" -and -not $hasElectron) { throw "Electron detection requires the electron package dependency" }
  if ($detectedType -eq "docker" -and -not $hasDocker) { throw "Docker detection requires Dockerfile" }

  $fallbackName = Split-Path -Leaf $script:ResolvedRepositoryRoot
  if ($detectedType -eq "flutter") {
    $content = [IO.File]::ReadAllText($flutterPath)
    $nameMatch = [regex]::Match($content, '(?m)^name:\s*(?<name>[A-Za-z0-9_.-]+)\s*$')
    $versionMatch = [regex]::Match($content, '(?m)^version:\s*(?<version>\d+\.\d+\.\d+)(?:\+\d+)?\s*$')
    if (-not $nameMatch.Success -or -not $versionMatch.Success) { throw "pubspec.yaml must contain a name and stable semantic version" }
    return [pscustomobject]@{
      ProjectType = "flutter"; ProjectName = $nameMatch.Groups["name"].Value; Version = $versionMatch.Groups["version"].Value
      VersionSource = "pubspec.yaml"; PackageManager = "flutter"; Package = $null; Manager = $null; BuildPath = $null
      VersionReadPattern = '(?m)^version:\s*(?<version>\d+\.\d+\.\d+)(?:\+\d+)?\s*$'
      VersionUpdatePattern = '(?m)^(version:\s*)\d+\.\d+\.\d+(?:\+\d+)?\s*$'
      HasTests = (Test-Path -LiteralPath (Join-Path $script:ResolvedRepositoryRoot "test") -PathType Container)
    }
  }

  if ($detectedType -eq "android") {
    $module = $androidModules[0]
    $versionMatch = [regex]::Match($module.Content, '(?m)^\s*versionName\s*(?:=\s*)?["''](?<version>\d+\.\d+\.\d+)["'']')
    if (-not $versionMatch.Success) { throw "Android application module must contain a static semantic versionName" }
    $settingsPath = @("settings.gradle.kts", "settings.gradle") | ForEach-Object { Join-Path $script:ResolvedRepositoryRoot $_ } | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    $name = $fallbackName
    if ($settingsPath) {
      $settings = [IO.File]::ReadAllText($settingsPath)
      $nameMatch = [regex]::Match($settings, '(?m)^\s*rootProject\.name\s*=\s*["''](?<name>[^"'']+)["'']')
      if ($nameMatch.Success) { $name = $nameMatch.Groups["name"].Value }
    }
    $localBuild = if (Test-Path -LiteralPath (Join-Path $script:ResolvedRepositoryRoot "gradlew.bat")) { ".\gradlew.bat test assembleRelease bundleRelease --no-daemon" } else { "gradle test assembleRelease bundleRelease --no-daemon" }
    return [pscustomobject]@{
      ProjectType = "android"; ProjectName = $name; Version = $versionMatch.Groups["version"].Value
      VersionSource = $module.BuildFile; PackageManager = "gradle"; Package = $null; Manager = $null; BuildPath = $module.Directory
      VersionReadPattern = '(?m)^\s*versionName\s*(?:=\s*)?["''](?<version>\d+\.\d+\.\d+)["'']'
      VersionUpdatePattern = '(?m)^(\s*versionName\s*(?:=\s*)?["''])\d+\.\d+\.\d+(["''])'
      AndroidLocalBuild = $localBuild
    }
  }

  if ($detectedType -eq "electron") {
    $name = [string](Get-OptionalProperty $packageManifest "productName" (Get-OptionalProperty $packageManifest "name" $fallbackName))
    $version = [string](Get-OptionalProperty $packageManifest "version" "")
    if ($version -notmatch '^\d+\.\d+\.\d+$') { throw "Electron package.json must contain a stable semantic version" }
    $scripts = Get-OptionalProperty $packageManifest "scripts"
    $buildScript = @("dist", "release", "package", "make", "build") | Where-Object { Test-PackageScript $packageManifest $_ } | Select-Object -First 1
    if (-not $buildScript) { throw "Electron package.json must define a dist, release, package, make, or build script" }
    $manager = Get-PackageManager
    $buildConfig = Get-OptionalProperty $packageManifest "build"
    $directories = Get-OptionalProperty $buildConfig "directories"
    $output = [string](Get-OptionalProperty $directories "output" "dist")
    if ([IO.Path]::IsPathRooted($output) -or $output -match '(^|[\\/])\.\.([\\/]|$)' -or $output -notmatch '^[A-Za-z0-9._/\\-]+$') {
      throw "Electron output directory must be a safe repository-relative path"
    }
    return [pscustomobject]@{
      ProjectType = "electron"; ProjectName = $name; Version = $version; VersionSource = "package.json"
      PackageManager = $manager.Name; Package = $packageManifest; Manager = $manager; BuildPath = $null
      ElectronBuildCommand = Get-PackageCommand $manager.Name $buildScript; ElectronOutput = $output
    }
  }

  if ($detectedType -eq "cmake") {
    $content = [IO.File]::ReadAllText($cmakePath)
    $projectMatch = [regex]::Match($content, '(?is)\bproject\s*\(\s*(?<name>[A-Za-z0-9_.+-]+)(?:(?!\)).)*\)')
    if (-not $projectMatch.Success) { throw "CMakeLists.txt must contain a project declaration" }
    $versionMatch = [regex]::Match($projectMatch.Value, '(?is)\bVERSION\s+(?<version>\d+\.\d+\.\d+)')
    $targets = @([regex]::Matches($content, '(?im)^\s*add_executable\s*\(\s*(?<name>[A-Za-z0-9_.+-]+)') | ForEach-Object { $_.Groups["name"].Value } | Sort-Object -Unique)
    if ($targets.Count -ne 1) { throw "CMake generation requires exactly one add_executable target" }
    $needsVersionFile = -not $versionMatch.Success
    return [pscustomobject]@{
      ProjectType = "cmake"; ProjectName = $projectMatch.Groups["name"].Value; Version = if ($needsVersionFile) { Get-InferredVersion } else { $versionMatch.Groups["version"].Value }
      VersionSource = if ($needsVersionFile) { "VERSION" } else { "CMakeLists.txt" }
      PackageManager = "cmake"; Package = $null; Manager = $null; BuildPath = $null
      CMakeTarget = $targets[0]; NeedsVersionFile = $needsVersionFile
    }
  }

  if ($detectedType -eq "docker") {
    $dockerContent = [IO.File]::ReadAllText($dockerPath)
    $titleMatch = [regex]::Match($dockerContent, '(?im)^\s*LABEL\s+org\.opencontainers\.image\.title\s*=\s*["'']?(?<name>[^"''\s]+)')
    $name = if ($titleMatch.Success) { $titleMatch.Groups["name"].Value } else { $fallbackName }
    return [pscustomobject]@{
      ProjectType = "docker"; ProjectName = $name; Version = Get-InferredVersion; VersionSource = "VERSION"
      PackageManager = "docker"; Package = $null; Manager = $null; BuildPath = "Dockerfile"
      NeedsVersionFile = -not (Test-Path -LiteralPath (Join-Path $script:ResolvedRepositoryRoot "VERSION"))
    }
  }
  if ($detectedType -eq "tauri") {
    $tauri = Read-JsonFile $tauriConfigPath "Tauri config"
    $tauriPackage = Get-OptionalProperty $tauri "package"
    $name = [string](Get-OptionalProperty $tauri "productName" (Get-OptionalProperty $tauriPackage "productName" $fallbackName))
    $version = [string](Get-OptionalProperty $tauri "version" (Get-OptionalProperty $tauriPackage "version" ""))
    if ($version -notmatch '^\d+\.\d+\.\d+$') { throw "Tauri config must contain a stable semantic version" }
    $package = $null
    if ($hasNode) { $package = Read-JsonFile $packagePath "package.json" }
    $manager = Get-PackageManager
    return [pscustomobject]@{
      ProjectType = "tauri"; ProjectName = $name; Version = $version
      VersionSource = "src-tauri/tauri.conf.json"; PackageManager = if ($hasNode) { $manager.Name } else { $null }
      Package = $package; Manager = $manager; BuildPath = $null
    }
  }

  if ($detectedType -eq "node") {
    $package = Read-JsonFile $packagePath "package.json"
    $name = [string](Get-OptionalProperty $package "name" $fallbackName)
    $version = [string](Get-OptionalProperty $package "version" "")
    if ($version -notmatch '^\d+\.\d+\.\d+$') { throw "package.json must contain a stable semantic version" }
    $manager = Get-PackageManager
    return [pscustomobject]@{
      ProjectType = "node"; ProjectName = $name; Version = $version
      VersionSource = "package.json"; PackageManager = $manager.Name
      Package = $package; Manager = $manager; BuildPath = $null
    }
  }

  if ($detectedType -eq "go") {
    $goMod = [IO.File]::ReadAllText($goModPath)
    $moduleMatch = [regex]::Match($goMod, '(?m)^module\s+(?<module>\S+)\s*$')
    if (-not $moduleMatch.Success) { throw "go.mod does not contain a module directive" }
    $module = $moduleMatch.Groups["module"].Value
    $name = ($module -split '/')[(-1)]
    $namedCommand = Join-Path $script:ResolvedRepositoryRoot ("cmd\" + $name)
    $buildPath = if (Test-Path -LiteralPath $namedCommand -PathType Container) { "./cmd/$name" } else { "." }
    return [pscustomobject]@{
      ProjectType = "go"; ProjectName = $name; Version = Get-InferredVersion
      VersionSource = "VERSION"; PackageManager = $null; Package = $null
      Manager = $null; BuildPath = $buildPath; NeedsVersionFile = -not (Test-Path -LiteralPath (Join-Path $script:ResolvedRepositoryRoot "VERSION"))
    }
  }

  if ($detectedType -eq "python") {
    $content = [IO.File]::ReadAllText($pythonPath)
    $sections = @(
      @{ Name = "project"; Prefix = '(?ms)^\[project\]\s*(?:(?!^\[).)*?' },
      @{ Name = "tool.poetry"; Prefix = '(?ms)^\[tool\.poetry\]\s*(?:(?!^\[).)*?' }
    )
    $selected = $null
    foreach ($section in $sections) {
      $nameMatch = [regex]::Match($content, $section.Prefix + '^name\s*=\s*["''](?<name>[^"'']+)["'']')
      $versionMatch = [regex]::Match($content, $section.Prefix + '^version\s*=\s*["''](?<version>\d+\.\d+\.\d+)["'']')
      if ($nameMatch.Success -and $versionMatch.Success) {
        $selected = [pscustomobject]@{ Name = $nameMatch.Groups["name"].Value; Version = $versionMatch.Groups["version"].Value; Section = $section.Prefix }
        break
      }
    }
    if (-not $selected) { throw "pyproject.toml must contain a static PEP 621 or Poetry name and semantic version" }
    $pythonManager = if (Test-Path -LiteralPath (Join-Path $script:ResolvedRepositoryRoot "uv.lock")) { "uv" }
      elseif (Test-Path -LiteralPath (Join-Path $script:ResolvedRepositoryRoot "poetry.lock")) { "poetry" }
      else { "pip" }
    return [pscustomobject]@{
      ProjectType = "python"; ProjectName = $selected.Name; Version = $selected.Version
      VersionSource = "pyproject.toml"; PackageManager = $pythonManager; Package = $null; Manager = $null; BuildPath = $null
      VersionReadPattern = $selected.Section + '^version\s*=\s*["''](?<version>\d+\.\d+\.\d+)["'']'
      VersionUpdatePattern = '(' + $selected.Section + '^version\s*=\s*["''])\d+\.\d+\.\d+(["''])'
      HasTests = (Test-Path -LiteralPath (Join-Path $script:ResolvedRepositoryRoot "tests") -PathType Container)
    }
  }

  if ($detectedType -eq "rust") {
    $content = [IO.File]::ReadAllText($cargoPath)
    $nameMatch = [regex]::Match($content, '(?ms)^\[package\]\s*(?:(?!^\[).)*?^name\s*=\s*"(?<name>[^"]+)"')
    $versionMatch = [regex]::Match($content, '(?ms)^\[package\]\s*(?:(?!^\[).)*?^version\s*=\s*"(?<version>\d+\.\d+\.\d+)"')
    if (-not $nameMatch.Success -or -not $versionMatch.Success) { throw "Cargo.toml must contain a non-workspace package name and stable semantic version" }
    return [pscustomobject]@{
      ProjectType = "rust"; ProjectName = $nameMatch.Groups["name"].Value; Version = $versionMatch.Groups["version"].Value
      VersionSource = "Cargo.toml"; PackageManager = "cargo"; Package = $null; Manager = $null; BuildPath = $null
    }
  }

  if ($detectedType -eq "dotnet") {
    $projectContent = [IO.File]::ReadAllText($dotnetProject.FullName)
    try { [xml]$projectXml = $projectContent } catch { throw ".NET project file is invalid XML: $($dotnetProject.FullName)" }
    $name = Get-XmlDescendantValue $projectXml "PackageId"
    if (-not $name) { $name = Get-XmlDescendantValue $projectXml "AssemblyName" }
    if (-not $name) { $name = [IO.Path]::GetFileNameWithoutExtension($dotnetProject.Name) }
    $projectRelative = Get-RelativeRepositoryPath $dotnetProject.FullName
    $versionElement = if ($projectContent -match '<Version>\s*\d+\.\d+\.\d+\s*</Version>') { "Version" }
      elseif ($projectContent -match '<VersionPrefix>\s*\d+\.\d+\.\d+\s*</VersionPrefix>') { "VersionPrefix" }
      else { $null }
    $needsVersionFile = $null -eq $versionElement
    $version = if ($needsVersionFile) { Get-InferredVersion }
      else { [regex]::Match($projectContent, "<$versionElement>\s*(?<version>\d+\.\d+\.\d+)\s*</$versionElement>").Groups["version"].Value }
    $targetFramework = Get-XmlDescendantValue $projectXml "TargetFramework"
    $frameworkMatch = [regex]::Match([string]$targetFramework, '^net(?<major>\d+)\.(?<minor>\d+)')
    $sdkVersion = if ($frameworkMatch.Success) { "$($frameworkMatch.Groups['major'].Value).$($frameworkMatch.Groups['minor'].Value).x" } else { "8.0.x" }
    return [pscustomobject]@{
      ProjectType = "dotnet"; ProjectName = $name; Version = $version
      VersionSource = if ($needsVersionFile) { "VERSION" } else { $projectRelative }
      PackageManager = "dotnet"; Package = $null; Manager = $null; BuildPath = $projectRelative
      VersionElement = $versionElement; NeedsVersionFile = $needsVersionFile; DotNetVersion = $sdkVersion
    }
  }

  $hasMaven = Test-Path -LiteralPath $mavenPath -PathType Leaf
  $hasGradle = (Test-Path -LiteralPath $gradlePath -PathType Leaf) -or (Test-Path -LiteralPath $gradleKtsPath -PathType Leaf)
  if ($hasMaven -and $hasGradle) { throw "Both Maven and Gradle manifests exist; use a repository-specific config" }
  if ($hasMaven) {
    $content = [IO.File]::ReadAllText($mavenPath)
    try { [xml]$pom = $content } catch { throw "pom.xml is invalid XML" }
    $artifactId = Get-XmlDirectValue $pom "artifactId"
    $version = Get-XmlDirectValue $pom "version"
    if (-not $artifactId -or $version -notmatch '^\d+\.\d+\.\d+$') { throw "pom.xml must contain a direct artifactId and stable semantic version" }
    $escapedArtifact = [regex]::Escape($artifactId)
    $readPattern = '(?ms)<artifactId>\s*' + $escapedArtifact + '\s*</artifactId>\s*<version>\s*(?<version>\d+\.\d+\.\d+)\s*</version>'
    $updatePattern = '(?ms)(<artifactId>\s*' + $escapedArtifact + '\s*</artifactId>\s*<version>\s*)\d+\.\d+\.\d+(\s*</version>)'
    $localBuild = if (Test-Path -LiteralPath (Join-Path $script:ResolvedRepositoryRoot "mvnw.cmd")) { ".\mvnw.cmd -B test package" } else { "mvn -B test package" }
    $workflowBuild = if (Test-Path -LiteralPath (Join-Path $script:ResolvedRepositoryRoot "mvnw")) { "./mvnw -B test package" } else { "mvn -B test package" }
    return [pscustomobject]@{
      ProjectType = "java"; ProjectName = $artifactId; Version = $version; VersionSource = "pom.xml"
      PackageManager = "maven"; Package = $null; Manager = $null; BuildPath = $null
      VersionReadPattern = $readPattern; VersionUpdatePattern = $updatePattern
      JavaLocalBuild = $localBuild; JavaWorkflowBuild = $workflowBuild; JavaArtifactDirectory = "target"; JavaCache = "maven"
    }
  }

  $gradleFile = if (Test-Path -LiteralPath $gradleKtsPath -PathType Leaf) { $gradleKtsPath } else { $gradlePath }
  $content = [IO.File]::ReadAllText($gradleFile)
  $versionMatch = [regex]::Match($content, '(?m)^\s*version\s*=\s*["''](?<version>\d+\.\d+\.\d+)["'']')
  if (-not $versionMatch.Success) { throw "Gradle build file must contain a static stable semantic version" }
  $settingsPath = @("settings.gradle.kts", "settings.gradle") | ForEach-Object { Join-Path $script:ResolvedRepositoryRoot $_ } | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
  $name = $fallbackName
  if ($settingsPath) {
    $settings = [IO.File]::ReadAllText($settingsPath)
    $nameMatch = [regex]::Match($settings, '(?m)^\s*rootProject\.name\s*=\s*["''](?<name>[^"'']+)["'']')
    if ($nameMatch.Success) { $name = $nameMatch.Groups["name"].Value }
  }
  $relativeGradle = Get-RelativeRepositoryPath $gradleFile
  $localBuild = if (Test-Path -LiteralPath (Join-Path $script:ResolvedRepositoryRoot "gradlew.bat")) { ".\gradlew.bat test build --no-daemon" } else { "gradle test build --no-daemon" }
  $workflowBuild = if (Test-Path -LiteralPath (Join-Path $script:ResolvedRepositoryRoot "gradlew")) { "./gradlew test build --no-daemon" } else { "gradle test build --no-daemon" }
  return [pscustomobject]@{
    ProjectType = "java"; ProjectName = $name; Version = $versionMatch.Groups["version"].Value; VersionSource = $relativeGradle
    PackageManager = "gradle"; Package = $null; Manager = $null; BuildPath = $null
    VersionReadPattern = '(?m)^\s*version\s*=\s*["''](?<version>\d+\.\d+\.\d+)["'']'
    VersionUpdatePattern = '(?m)^(\s*version\s*=\s*["''])\d+\.\d+\.\d+(["''])'
    JavaLocalBuild = $localBuild; JavaWorkflowBuild = $workflowBuild; JavaArtifactDirectory = "build/libs"; JavaCache = "gradle"
  }
}
