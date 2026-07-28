# Internal NUL-safe Git transport, ignore-state, index, and snapshot operations.

function ConvertTo-NativeArgument([string]$Value) {
  if ($Value -notmatch '[\s"]') { return $Value }
  $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
  $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
  return '"' + $escaped + '"'
}
function Invoke-GitRaw(
  [string[]]$Arguments,
  [AllowNull()][string]$StandardInput = $null,
  [bool]$AllowFailure = $false
) {
  $gitCommand = Get-Command git -ErrorAction Stop
  $startInfo = [Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $gitCommand.Source
  $startInfo.WorkingDirectory = $script:Root
  $startInfo.Arguments = (@($Arguments | ForEach-Object { ConvertTo-NativeArgument ([string]$_) }) -join " ")
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  $startInfo.RedirectStandardInput = $null -ne $StandardInput
  $startInfo.StandardOutputEncoding = $script:Utf8NoBom
  $startInfo.StandardErrorEncoding = $script:Utf8NoBom
  $process = [Diagnostics.Process]::new()
  $process.StartInfo = $startInfo
  try {
    if (-not $process.Start()) { throw "Could not start git" }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if ($null -ne $StandardInput) {
      $process.StandardInput.Write($StandardInput)
      $process.StandardInput.Close()
    }
    $process.WaitForExit()
    $stdout = $stdoutTask.Result
    $stderr = $stderrTask.Result
    $exitCode = $process.ExitCode
  }
  finally {
    $process.Dispose()
  }
  if ($exitCode -ne 0 -and -not $AllowFailure) {
    throw "git $($Arguments -join ' ') failed: $($stderr.TrimEnd("`r", "`n"))"
  }
  return [pscustomobject]@{
    ExitCode = $exitCode
    Output = $stdout
    Error = $stderr
  }
}

function Invoke-GitCaptured([string[]]$Arguments, [bool]$AllowFailure = $false) {
  $result = Invoke-GitRaw -Arguments $Arguments -AllowFailure $AllowFailure
  return [pscustomobject]@{
    ExitCode = $result.ExitCode
    Output = $result.Output.TrimEnd("`r", "`n")
  }
}

function Invoke-GitChecked([string[]]$Arguments) {
  $result = Invoke-GitCaptured $Arguments
  foreach ($line in @($result.Output -split "`r?`n" | Where-Object { $_ })) { Write-Host $line }
}

function Get-GitPathList([string[]]$Arguments) {
  $separatorIndex = [Array]::IndexOf([object[]]$Arguments, "--")
  $commandArguments = if ($separatorIndex -ge 0) {
    $beforeSeparator = if ($separatorIndex -gt 0) { @($Arguments[0..($separatorIndex - 1)]) } else { @() }
    $beforeSeparator + @("-z") + @($Arguments[$separatorIndex..($Arguments.Count - 1)])
  }
  else {
    @($Arguments) + @("-z")
  }
  $gitArguments = @("-c", "core.quotepath=false") + $commandArguments
  $result = Invoke-GitRaw $gitArguments
  if ([string]::IsNullOrEmpty($result.Output)) { return @() }
  return @(
    $result.Output -split "`0" |
      Where-Object { -not [string]::IsNullOrEmpty($_) } |
      ForEach-Object { $_.Replace("\", "/") }
  )
}


function Test-PathMatches($Candidate, [string]$Path) {
  return [regex]::IsMatch($Path.Replace("\", "/"), [string]$Candidate.matchRegex)
}

function Get-CheckIgnoreRecords([string[]]$Paths) {
  if ($Paths.Count -eq 0) { return @() }
  $records = @()
  foreach ($path in @($Paths)) {
    $record = Get-CheckIgnoreRecord ([string]$path)
    if ($record) { $records += $record }
  }
  return $records
}

function Get-CheckIgnoreRecord([string]$Path) {
  $result = Invoke-GitCaptured @("-c", "core.quotepath=false", "check-ignore", "-v", "--no-index", "--", $Path) $true
  if ($result.ExitCode -eq 1) { return $null }
  if ($result.ExitCode -ne 0) { throw "git check-ignore failed for $Path" }
  $line = @($result.Output -split "`r?`n" | Where-Object { $_ } | Select-Object -Last 1)
  if (-not $line) { return $null }
  $match = [regex]::Match([string]$line, '^(?<source>.*?):(?<line>\d+):(?<pattern>[^\t]+)\t(?<path>.*)$')
  if (-not $match.Success) { throw "Could not parse git check-ignore output for $Path" }
  return [pscustomobject][ordered]@{
    path = $match.Groups["path"].Value.Replace("\", "/")
    pattern = $match.Groups["pattern"].Value
    source = $match.Groups["source"].Value.Replace("\", "/")
    line = [int]$match.Groups["line"].Value
  }
}

function Test-IsIgnored([string]$Path) {
  $record = Get-CheckIgnoreRecord $Path
  if (-not $record) { return $false }
  return -not ([string]$record.pattern).StartsWith("!")
}

function Test-CandidateCovered($Candidate, [string[]]$MatchedPaths) {
  if (-not (Test-IsIgnored ([string]$Candidate.samplePath))) { return $false }
  foreach ($path in @($MatchedPaths)) {
    if (-not (Test-IsIgnored $path)) { return $false }
  }
  return $true
}

function Get-IgnoredSensitivePaths {
  $pathSpecs = @(
    ".env", ".env.*", ".envrc",
    ":(glob)**/.env", ":(glob)**/.env.*", ":(glob)**/.envrc",
    ":(glob)**/id_rsa", ":(glob)**/id_dsa", ":(glob)**/id_ecdsa", ":(glob)**/id_ed25519",
    ":(glob)**/*.pem", ":(glob)**/*.p12", ":(glob)**/*.pfx", ":(glob)**/*.key",
    ":(glob)**/*.keystore", ":(glob)**/*.jks",
    ":(glob)**/.last-token", ":(glob)**/auth-token", ":(glob)**/session-token", ":(glob)**/access-token",
    ":(glob).claude/{credentials,credential,auth,token,tokens}.json",
    ":(glob).cursor/{credentials,credential,auth,token,tokens}.json",
    ":(glob).codex/{credentials,credential,auth,token,tokens}.json",
    ":(glob).gemini/{credentials,credential,auth,token,tokens}.json",
    ":(glob).serena/{credentials,credential,auth,token,tokens}.json",
    ":(glob).continue/{credentials,credential,auth,token,tokens}.json",
    ":(glob).opencode/{credentials,credential,auth,token,tokens}.json"
  )
  return @(Get-GitPathList (@("ls-files", "--others", "--ignored", "--exclude-standard", "--") + $pathSpecs))
}

function Test-CandidateReferenced($Candidate) {
  $token = [string]$Candidate.referenceToken
  if ([string]::IsNullOrWhiteSpace($token)) { return $false }
  $result = Invoke-GitCaptured @("-c", "core.quotepath=false", "grep", "-n", "-I", "-F", "--", $token) $true
  if ($result.ExitCode -eq 1) { return $false }
  if ($result.ExitCode -ne 0) { return $true }
  foreach ($line in @($result.Output -split "`r?`n" | Where-Object { $_ })) {
    $sourcePath = ($line -split ':', 2)[0].Replace("\", "/")
    if ($sourcePath -eq ".gitignore") { continue }
    if (-not (Test-PathMatches $Candidate $sourcePath)) { return $true }
  }
  return $false
}

function Get-ProtectedPaths([string[]]$TrackedPaths, [string[]]$SkillRoots) {
  $pattern = '(?i)(^|/)(?:package-lock\.json|pnpm-lock\.yaml|yarn\.lock|bun\.lockb?|Cargo\.lock|go\.sum|poetry\.lock|uv\.lock|Pipfile\.lock|gradle\.lockfile)$|(?i)^\.github/workflows/'
  $protected = @($TrackedPaths | Where-Object { $_ -match $pattern })
  foreach ($skillRoot in @($SkillRoots)) {
    $normalizedRoot = ([string]$skillRoot).Replace("\", "/").Trim("/")
    if ([string]::IsNullOrEmpty($normalizedRoot)) {
      $protected += @($TrackedPaths | Where-Object { $_.Replace("\", "/") -ine ".codex-release.json" })
      continue
    }
    $prefix = "$normalizedRoot/"
    $protected += @($TrackedPaths | Where-Object {
      $_.Replace("\", "/").StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
    })
  }
  return @($protected | Sort-Object -Unique)
}

function Get-SensitivePaths([string[]]$Paths) {
  return @($Paths | Where-Object {
    $leaf = Get-PortableLeafName $_
    $isExample = $leaf -match '(?i)(?:\.example|\.sample|\.template)$'
    $isCredential = $_ -match '(?i)(^|/)(?:\.env(?:\..+)?|\.envrc|id_(?:rsa|dsa|ecdsa|ed25519)|[^/]+\.(?:pem|p12|pfx|key|keystore|jks))$'
    $isAgentToken = $_ -match '(?i)(^|/)(?:\.last-token|auth-token|session-token|access-token)$'
    $isAgentCredentialFile = $_ -match '(?i)^\.(?:claude|cursor|codex|gemini|serena|continue|opencode)/(?:credentials?|auth|tokens?)\.json$'
    -not $isExample -and ($isCredential -or $isAgentToken -or $isAgentCredentialFile)
  } | Sort-Object -Unique)
}

function Get-TrackedButIgnored([string[]]$TrackedPaths) {
  return @(
    Get-CheckIgnoreRecords $TrackedPaths |
      Where-Object { -not ([string]$_.pattern).StartsWith("!") } |
      Sort-Object path -Unique
  )
}

function Get-HistoricalGeneratedPaths($Candidates) {
  $result = Invoke-GitRaw @("-c", "core.quotepath=false", "log", "--all", "--pretty=format:", "--name-only", "-z") $null $true
  if ($result.ExitCode -ne 0) { return @() }
  $paths = @()
  foreach ($record in @($result.Output -split "`0" | Where-Object { $_ })) {
    $path = ([string]$record).TrimStart("`r", "`n").Replace("\", "/")
    if ([string]::IsNullOrEmpty($path)) { continue }
    foreach ($candidate in $Candidates) {
      if (Test-PathMatches $candidate $path) { $paths += $path; break }
    }
    if ($paths.Count -ge 200) { break }
  }
  return @($paths | Sort-Object -Unique)
}


function Backup-Index {
  $indexPath = Join-Path $script:GitDirectory "index"
  return [pscustomobject]@{
    path = $indexPath
    exists = Test-Path -LiteralPath $indexPath -PathType Leaf
    bytes = if (Test-Path -LiteralPath $indexPath -PathType Leaf) { [IO.File]::ReadAllBytes($indexPath) } else { $null }
  }
}

function Restore-Index($Backup) {
  if ($Backup.exists) { [IO.File]::WriteAllBytes([string]$Backup.path, [byte[]]$Backup.bytes) }
  elseif (Test-Path -LiteralPath ([string]$Backup.path) -PathType Leaf) { Remove-Item -LiteralPath ([string]$Backup.path) -Force }
}


function Get-FileSnapshot([string[]]$Paths) {
  $records = @()
  foreach ($path in @($Paths | Sort-Object -Unique)) {
    $fullPath = Join-Path $script:Root $path
    if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
      $records += [pscustomobject]@{ path = $path; hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $fullPath).Hash }
    }
  }
  return $records
}

function Assert-FileSnapshot($Snapshot) {
  foreach ($record in @($Snapshot)) {
    $fullPath = Join-Path $script:Root ([string]$record.path)
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { throw "Local file was removed while untracking: $($record.path)" }
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $fullPath).Hash -ne [string]$record.hash) {
      throw "Local file changed while untracking: $($record.path)"
    }
  }
}
