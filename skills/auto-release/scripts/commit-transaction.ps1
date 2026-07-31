# Internal staged-change validation and transactional commit operations.

function Get-GitDirectory {
  $gitDirectory = Invoke-GitCaptured @("rev-parse", "--git-dir")
  if (-not [IO.Path]::IsPathRooted($gitDirectory)) { $gitDirectory = Join-Path $script:ResolvedRepositoryRoot $gitDirectory }
  return Get-NormalizedPath $gitDirectory
}

function Backup-GitIndex {
  $indexPath = Join-Path (Get-GitDirectory) "index"
  return [pscustomobject]@{
    Path = $indexPath
    Exists = Test-Path -LiteralPath $indexPath -PathType Leaf
    Bytes = if (Test-Path -LiteralPath $indexPath -PathType Leaf) { [IO.File]::ReadAllBytes($indexPath) } else { $null }
  }
}

function Restore-GitIndex($Backup) {
  if ($Backup.Exists) { [IO.File]::WriteAllBytes($Backup.Path, [byte[]]$Backup.Bytes) }
  elseif (Test-Path -LiteralPath $Backup.Path -PathType Leaf) { Remove-Item -LiteralPath $Backup.Path -Force }
}

function Assert-NoConflicts {
  $conflicts = Invoke-GitCaptured @("diff", "--name-only", "--diff-filter=U")
  if ($conflicts) { throw "Unresolved Git conflicts: $conflicts" }
}

function Assert-NoStagedSecrets {
  $paths = @((Invoke-GitCaptured @("diff", "--cached", "--name-only", "--diff-filter=ACMR")) -split "`r?`n" | Where-Object { $_ })
  foreach ($path in $paths) {
    $normalized = $path.Replace("\", "/")
    $leaf = [IO.Path]::GetFileName($normalized)
    $isExample = $leaf -match '(?i)\.(?:example|sample|template)$'
    if (-not $isExample -and $normalized -match '(?i)(^|/)(?:\.env(?:\..+)?|id_(?:rsa|dsa|ecdsa|ed25519)|credentials?(?:\..+)?|secrets?(?:\..+)?|[^/]+\.(?:pem|p12|pfx|key))$') {
      throw "Refusing to commit possible secret file: $path"
    }
  }
  $diff = Invoke-GitCaptured @("diff", "--cached", "--no-ext-diff", "--unified=0", "--", ".")
  if ($diff -match '(?m)^\+(?!\+\+).*(?:ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[A-Z0-9]{16}|-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----)') {
    throw "Refusing to commit content that looks like a credential"
  }
}

function Get-ChangedPaths {
  $tracked = @((Invoke-GitCaptured @("diff", "HEAD", "--name-only", "--no-renames", "--")) -split "`r?`n" | Where-Object { $_ })
  $untracked = @((Invoke-GitCaptured @("ls-files", "--others", "--exclude-standard")) -split "`r?`n" | Where-Object { $_ })
  return @($tracked + $untracked | ForEach-Object { $_.Replace("\", "/") } | Sort-Object -Unique)
}

function Assert-ReleaseWorkingTreeClean {
  Assert-NoConflicts
  $status = Invoke-GitCaptured @("status", "--porcelain", "--untracked-files=all")
  if ($status) {
    throw "Release requires a clean working tree; run CommitPush separately before Release: $status"
  }
}

function Get-ReleaseCommitPaths($Config, [string[]]$AutomationPaths) {
  $paths = @()
  foreach ($path in @($AutomationPaths)) {
    $paths += Get-PlanRelativePath ([string]$path)
  }
  $version = Get-OptionalProperty $Config "version"
  foreach ($update in @(Get-OptionalProperty $version "updates" @())) {
    $paths += Get-PlanRelativePath ([string](Get-OptionalProperty $update "path" ""))
  }
  return @($paths | Sort-Object -Unique)
}

function Assert-ReleaseChangesAllowed([string[]]$AllowedPaths) {
  $allowed = @{}
  foreach ($path in @($AllowedPaths)) {
    $allowed[(Get-PlanRelativePath ([string]$path))] = $true
  }
  $actual = @(Get-ChangedPaths)
  $unexpected = @($actual | Where-Object { -not $allowed.ContainsKey($_) })
  if ($unexpected.Count -gt 0) {
    throw "Release created changes outside its allowed paths: $($unexpected -join ', '). Commit them with CommitPush separately or fix the build."
  }
  return $actual
}

function Get-PlanRelativePath([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path)) { throw "Commit plan contains an empty path" }
  if ($Path.IndexOfAny([char[]]@("*", "?", "[", "]")) -ge 0) {
    throw "Commit plan paths must be exact and cannot contain wildcards: $Path"
  }
  $fullPath = if ([IO.Path]::IsPathRooted($Path)) {
    [IO.Path]::GetFullPath($Path)
  }
  else {
    [IO.Path]::GetFullPath((Join-Path $script:ResolvedRepositoryRoot $Path))
  }
  $rootPrefix = $script:ResolvedRepositoryRoot + [IO.Path]::DirectorySeparatorChar
  if (-not $fullPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Commit plan path escapes repository root: $Path"
  }
  $relative = $fullPath.Substring($rootPrefix.Length).Replace("\", "/")
  if ($relative -match '(^|/)\.git(/|$)') { throw "Commit plan cannot include Git metadata: $Path" }
  return $relative
}

function Get-CommitPlanFilePath {
  if ([string]::IsNullOrWhiteSpace($CommitPlanPath)) {
    throw "CommitPlanPath is required when CommitStrategy is AutoSplit"
  }
  $fullPath = if ([IO.Path]::IsPathRooted($CommitPlanPath)) {
    [IO.Path]::GetFullPath($CommitPlanPath)
  }
  else {
    [IO.Path]::GetFullPath((Join-Path $script:ResolvedRepositoryRoot $CommitPlanPath))
  }
  $gitDirectory = Get-GitDirectory
  $gitPrefix = $gitDirectory + [IO.Path]::DirectorySeparatorChar
  if (-not $fullPath.StartsWith($gitPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Commit plan must be stored under the Git directory: $gitDirectory"
  }
  if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { throw "Commit plan not found: $fullPath" }
  return $fullPath
}

function Get-PathContentFingerprint([string[]]$Paths) {
  $entries = @()
  foreach ($path in @($Paths | Sort-Object -Unique)) {
    $fullPath = [IO.Path]::GetFullPath((Join-Path $script:ResolvedRepositoryRoot $path))
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
      $entries += "$path`:missing"
      continue
    }
    $entries += "$path`:$((Get-FileHash -Algorithm SHA256 -LiteralPath $fullPath).Hash)"
  }
  $bytes = $script:Utf8NoBom.GetBytes(($entries -join "`n"))
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "") }
  finally { $sha.Dispose() }
}

function Read-CommitPlan($CommitAnalysis, $CommitLanguageAnalysis) {
  $path = Get-CommitPlanFilePath
  try { $rawPlan = Get-Content -Raw -Encoding UTF8 -LiteralPath $path | ConvertFrom-Json }
  catch { throw "Commit plan is invalid JSON: $path" }
  if ([int](Get-OptionalProperty $rawPlan "schemaVersion" 0) -ne 1) {
    throw "Commit plan schemaVersion must be 1"
  }
  $baseHead = Invoke-GitCaptured @("rev-parse", "HEAD")
  $plannedBase = [string](Get-OptionalProperty $rawPlan "baseHead" "")
  if ($plannedBase -and $plannedBase -ne $baseHead) {
    throw "Commit plan baseHead does not match the current HEAD"
  }
  $groups = @($rawPlan.groups)
  if ($groups.Count -lt 2) { throw "AutoSplit requires at least two commit groups" }
  if ($groups.Count -gt $MaxCommits) { throw "Commit plan exceeds MaxCommits ($MaxCommits)" }

  $actualPaths = @(Get-ChangedPaths)
  if ($actualPaths.Count -eq 0) { throw "There are no changes to commit" }
  $actualSet = @{}
  foreach ($pathValue in $actualPaths) { $actualSet[$pathValue] = $true }
  $plannedSet = @{}
  $normalizedGroups = @()
  foreach ($group in $groups) {
    $summaryValue = [string](Get-OptionalProperty $group "summary" "")
    Assert-CommitSummaryStyle -Summary $summaryValue -Analysis $CommitAnalysis
    Assert-CommitSummaryLanguage -Summary $summaryValue -Analysis $CommitLanguageAnalysis
    $paths = @($group.paths | ForEach-Object { Get-PlanRelativePath ([string]$_) })
    if ($paths.Count -eq 0) { throw "Commit group has no paths: $summaryValue" }
    foreach ($relative in $paths) {
      if ($plannedSet.ContainsKey($relative)) { throw "Commit plan path appears more than once: $relative" }
      if (-not $actualSet.ContainsKey($relative)) { throw "Commit plan includes an unchanged path: $relative" }
      $plannedSet[$relative] = $true
    }
    $normalizedGroups += [pscustomobject][ordered]@{
      summary = $summaryValue
      paths = @($paths | Sort-Object -Unique)
    }
  }
  $missing = @($actualPaths | Where-Object { -not $plannedSet.ContainsKey($_) })
  if ($missing.Count -gt 0) { throw "Commit plan does not cover all changes: $($missing -join ', ')" }
  return [pscustomobject][ordered]@{
    schemaVersion = 1
    baseHead = $baseHead
    groups = $normalizedGroups
    path = $path
  }
}

function Commit-PlannedChanges([bool]$Push) {
  Assert-NoConflicts
  Assert-LocalConfigReadyForCommit
  $config = Read-ReleaseConfig
  $commitAnalysis = Get-ConfiguredCommitStyleAnalysis $config
  $commitLanguageAnalysis = Get-ConfiguredCommitLanguageAnalysis $config
  $plan = Read-CommitPlan $commitAnalysis $commitLanguageAnalysis
  $remoteState = Assert-RemoteReady $config $false
  $target = Get-BranchAndRemote $config $false
  $baseHead = [string]$plan.baseHead
  $indexBackup = Backup-GitIndex
  $allPaths = @($plan.groups | ForEach-Object { @($_.paths) })
  $configRelativePath = Get-ConfigRelativePath
  $configNeedsIndexRemoval = $allPaths -contains $configRelativePath
  $configFile = Resolve-RepositoryPath $ConfigPath
  $configBytes = if ($configNeedsIndexRemoval -and (Test-Path -LiteralPath $configFile -PathType Leaf)) {
    [IO.File]::ReadAllBytes($configFile)
  }
  else {
    $null
  }
  $contentFingerprint = Get-PathContentFingerprint $allPaths
  $transactionBranch = "auto-release/transaction-$([guid]::NewGuid().ToString('N'))"
  $commits = @()
  $finalized = $false
  try {
    Invoke-GitChecked @("add", "-A")
    Assert-NoStagedSecrets
    Restore-GitIndex $indexBackup

    Invoke-GitChecked @("switch", "-c", $transactionBranch, $baseHead)
    foreach ($group in @($plan.groups)) {
      Invoke-GitChecked @("reset", "--mixed", "HEAD")
      Invoke-GitChecked (@("add", "-A", "--") + @($group.paths))
      if ($configNeedsIndexRemoval -and @($group.paths) -contains $configRelativePath) {
        Invoke-GitChecked @("rm", "--cached", "--ignore-unmatch", "--", $configRelativePath)
      }
      Assert-NoStagedSecrets
      Invoke-GitChecked @("diff", "--cached", "--check")
      & git -C $script:ResolvedRepositoryRoot diff --cached --quiet
      if ($LASTEXITCODE -eq 0) { throw "Commit group has no staged changes: $($group.summary)" }
      if ($LASTEXITCODE -ne 1) { throw "git diff --cached --quiet failed" }
      Invoke-GitChecked @("commit", "-m", [string]$group.summary)
      $commits += [pscustomobject][ordered]@{
        summary = [string]$group.summary
        head = Invoke-GitCaptured @("rev-parse", "HEAD")
        paths = @($group.paths)
      }
    }

    if ((Get-PathContentFingerprint $allPaths) -ne $contentFingerprint) {
      throw "Planned files changed during the commit transaction"
    }
    $remaining = Invoke-GitCaptured @("status", "--porcelain", "--untracked-files=all")
    if ($remaining) { throw "Unplanned changes appeared during the commit transaction: $remaining" }

    Invoke-GitChecked @("switch", $target.Branch)
    Invoke-GitChecked @("merge", "--ff-only", $transactionBranch)
    if ($null -ne $configBytes) {
      [IO.File]::WriteAllBytes($configFile, [byte[]]$configBytes)
    }
    $finalized = $true
    Invoke-GitChecked @("branch", "-D", $transactionBranch)

    if ($Push) {
      $remoteState = Assert-RemoteReady $config $false
      $arguments = @("push", $remoteState.Remote, $remoteState.Branch)
      if (-not $remoteState.Exists) { $arguments = @("push", "--set-upstream", $remoteState.Remote, $remoteState.Branch) }
      Invoke-GitChecked $arguments
      Write-Host "Pushed $($commits.Count) commits: $($remoteState.Remote)/$($remoteState.Branch)"
    }
  }
  catch {
    $failure = $_
    if (-not $finalized) {
      try {
        $currentBranch = Invoke-GitCaptured @("branch", "--show-current")
        if ($currentBranch -eq $transactionBranch) {
          Invoke-GitChecked @("reset", "--mixed", $baseHead)
          Invoke-GitChecked @("switch", $target.Branch)
        }
        Restore-GitIndex $indexBackup
        if ($null -ne $configBytes) {
          [IO.File]::WriteAllBytes($configFile, [byte[]]$configBytes)
        }
        $branchExists = Invoke-GitCaptured @("branch", "--list", $transactionBranch)
        if ($branchExists) { Invoke-GitChecked @("branch", "-D", $transactionBranch) }
      }
      catch { Write-Warning "Commit transaction rollback needs manual inspection: $($_.Exception.Message)" }
    }
    throw $failure
  }

  return [pscustomobject][ordered]@{
    Committed = $commits.Count -gt 0
    CommitCount = $commits.Count
    Commits = $commits
    Head = Invoke-GitCaptured @("rev-parse", "HEAD")
    CommitStyle = $commitAnalysis
    CommitLanguage = $commitLanguageAnalysis
  }
}

function Commit-ReleaseChanges(
  [string[]]$AllowedPaths,
  [string]$ExpectedSourceFingerprint = ""
) {
  Assert-NoConflicts
  Assert-LocalConfigReadyForCommit
  $config = Read-ReleaseConfig
  $commitAnalysis = Assert-ConfiguredCommitSummary $config
  $commitLanguageAnalysis = $script:CommitLanguageAnalysis
  Assert-RemoteReady $config $true | Out-Null
  $actualPaths = @(Assert-ReleaseChangesAllowed $AllowedPaths)
  if ($ExpectedSourceFingerprint -and (Get-SourceFingerprint $config) -ne $ExpectedSourceFingerprint) {
    throw "Source files changed after the verified build; release stopped before commit"
  }

  $indexBackup = Backup-GitIndex
  $committed = $false
  try {
    if ($actualPaths.Count -gt 0) {
      Invoke-GitChecked (@("add", "-A", "--") + $actualPaths)
      Assert-NoStagedSecrets
      Invoke-GitChecked @("diff", "--cached", "--check")
      $stagedPaths = @((Invoke-GitCaptured @("diff", "--cached", "--name-only", "--no-renames", "--")) -split "`r?`n" | Where-Object { $_ })
      $unexpectedStaged = @($stagedPaths | Where-Object { $_.Replace("\", "/") -notin $actualPaths })
      if ($unexpectedStaged.Count -gt 0) {
        throw "Release staged paths outside its allowlist: $($unexpectedStaged -join ', ')"
      }
      Invoke-GitChecked @("commit", "-m", $Summary)
      $committed = $true
      Write-Host "Committed release-owned changes: $Summary"
    }
    else {
      Write-Host "No release-owned changes to commit"
    }
  }
  catch {
    if (-not $committed) { Restore-GitIndex $indexBackup }
    throw
  }

  $remaining = @(Get-ChangedPaths)
  if ($remaining.Count -gt 0) {
    throw "Release left uncommitted changes after ReleaseCommit: $($remaining -join ', ')"
  }
  return [pscustomobject]@{
    Committed = $committed
    Head = Invoke-GitCaptured @("rev-parse", "HEAD")
    CommitStyle = $commitAnalysis
    CommitLanguage = $commitLanguageAnalysis
    Paths = $actualPaths
  }
}

function Commit-AllChanges(
  [bool]$Push,
  [string]$ExpectedSourceFingerprint = "",
  [bool]$UseConfiguredBranch = $true
) {
  Assert-NoConflicts
  Assert-LocalConfigReadyForCommit
  $config = Read-ReleaseConfig
  $commitAnalysis = Assert-ConfiguredCommitSummary $config
  $commitLanguageAnalysis = $script:CommitLanguageAnalysis
  $remoteState = Assert-RemoteReady $config $UseConfiguredBranch
  $indexBackup = Backup-GitIndex
  $committed = $false
  try {
    Invoke-GitChecked @("add", "-A")
    Assert-NoStagedSecrets
    if ($ExpectedSourceFingerprint -and (Get-SourceFingerprint $config) -ne $ExpectedSourceFingerprint) {
      throw "Source files changed after the verified build; release stopped before commit"
    }
    & git -C $script:ResolvedRepositoryRoot diff --cached --quiet
    $hasChanges = $LASTEXITCODE -eq 1
    if ($LASTEXITCODE -notin @(0, 1)) { throw "git diff --cached --quiet failed" }
    if ($hasChanges) {
      Invoke-GitChecked @("commit", "-m", $Summary)
      $committed = $true
      Write-Host "Committed all changes: $Summary"
    }
    else {
      Write-Host "No working tree or index changes to commit"
    }
  }
  catch {
    if (-not $committed) { Restore-GitIndex $indexBackup }
    throw
  }

  if ($Push) {
    $arguments = @("push", $remoteState.Remote, $remoteState.Branch)
    if (-not $remoteState.Exists) { $arguments = @("push", "--set-upstream", $remoteState.Remote, $remoteState.Branch) }
    Invoke-GitChecked $arguments
    Write-Host "Pushed: $($remoteState.Remote)/$($remoteState.Branch)"
  }
  return [pscustomobject]@{
    Committed = $committed
    Head = Invoke-GitCaptured @("rev-parse", "HEAD")
    CommitStyle = $commitAnalysis
    CommitLanguage = $commitLanguageAnalysis
  }
}
