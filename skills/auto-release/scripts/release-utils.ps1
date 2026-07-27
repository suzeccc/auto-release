$ErrorActionPreference = "Stop"

function Get-CommitConfigProperty($Config, [string]$Name, $Default = $null) {
  if ($null -eq $Config) { return $Default }
  $property = $Config.PSObject.Properties[$Name]
  if ($null -eq $property) { return $Default }
  return $property.Value
}

function Get-CommitSubjectStyle([string]$Subject) {
  $conventionalPattern = '^[a-z][a-z0-9-]*(?:\([^)]+\))?!?:\s+\S'
  if ($Subject -match $conventionalPattern) { return "conventional" }
  return "non-conventional"
}

function Get-CommitStylePattern([string]$Style) {
  if ($Style -ne "conventional") { throw "Unsupported commit style: $Style" }
  return '^[a-z][a-z0-9-]*(?:\([^)]+\))?!?:\s+\S'
}

function Get-CommitStyleFormat([string]$Style) {
  if ($Style -ne "conventional") { throw "Unsupported commit style: $Style" }
  return "type(scope): description or type: description"
}

function Get-CommitStyleAnalysis {
  [CmdletBinding()]
  param(
    [string[]]$Subjects = @(),
    [ValidateSet("auto", "conventional", "off")]
    [string]$Policy = "conventional",
    [int]$MinimumSamples = 3,
    [double]$ConfidenceThreshold = 0.6
  )

  if ($MinimumSamples -lt 1) { throw "Commit minimumSamples must be positive" }
  if ($ConfidenceThreshold -le 0 -or $ConfidenceThreshold -gt 1) {
    throw "Commit confidenceThreshold must be greater than 0 and at most 1"
  }

  $filtered = @(
    $Subjects |
      Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) -and [string]$_ -notmatch '^Merge\s' }
  )
  $counts = [ordered]@{ conventional = 0; nonConventional = 0 }
  foreach ($subject in $filtered) {
    $style = Get-CommitSubjectStyle ([string]$subject)
    if ($style -eq "conventional") {
      $counts.conventional = [int]$counts.conventional + 1
    }
    else {
      $counts.nonConventional = [int]$counts.nonConventional + 1
    }
  }

  $sampleCount = $filtered.Count
  $selectedStyle = "conventional"
  $fallbackUsed = $false
  $reason = if ($Policy -eq "conventional") { "required" } else { "legacy-policy-normalized" }
  $confidence = 1.0

  return [pscustomobject][ordered]@{
    policy = "conventional"
    configuredPolicy = $Policy
    selectedStyle = $selectedStyle
    sampleCount = $sampleCount
    minimumSamples = $MinimumSamples
    confidence = $confidence
    confidenceThreshold = $ConfidenceThreshold
    fallbackUsed = $fallbackUsed
    fallback = "conventional"
    reason = $reason
    expectedFormat = Get-CommitStyleFormat $selectedStyle
    pattern = Get-CommitStylePattern $selectedStyle
    counts = [pscustomobject]$counts
    examples = @($filtered | Select-Object -First 3)
  }
}

function Get-RepositoryCommitStyleAnalysis {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$RepositoryRoot,
    $CommitConfig = $null
  )

  $policy = [string](Get-CommitConfigProperty $CommitConfig "policy" "conventional")
  if ($policy -notin @("auto", "conventional", "off")) {
    throw "Unsupported commit policy: $policy"
  }
  $analyzeCount = [int](Get-CommitConfigProperty $CommitConfig "analyzeCount" 30)
  $minimumSamples = [int](Get-CommitConfigProperty $CommitConfig "minimumSamples" 3)
  $confidenceThreshold = [double](Get-CommitConfigProperty $CommitConfig "confidenceThreshold" 0.6)
  $fallback = [string](Get-CommitConfigProperty $CommitConfig "fallback" "conventional")
  if ($analyzeCount -lt 1) { throw "Commit analyzeCount must be positive" }
  if ($fallback -ne "conventional") { throw "Commit fallback must be conventional" }

  return Get-CommitStyleAnalysis `
    -Subjects @() `
    -Policy $policy `
    -MinimumSamples $minimumSamples `
    -ConfidenceThreshold $confidenceThreshold
}

function Get-CommitDescription([string]$Subject) {
  if ([string]::IsNullOrWhiteSpace($Subject)) { return "" }
  if ($Subject -match '^[a-z][a-z0-9-]*(?:\([^)]+\))?!?:\s+') {
    return ($Subject -replace '^[a-z][a-z0-9-]*(?:\([^)]+\))?!?:\s+', '')
  }
  # Legacy prefixes are stripped only so PromptLanguage Auto can classify old history.
  if ($Subject -match '^[A-Z][A-Z0-9]+-\d+(?::|\s+-?)\s*') {
    return ($Subject -replace '^[A-Z][A-Z0-9]+-\d+(?::|\s+-?)\s*', '')
  }
  if ($Subject -match '^\[[^\]]+\]\s+') { return ($Subject -replace '^\[[^\]]+\]\s+', '') }
  if ($Subject -match '^(?::[a-z0-9_+-]+:|\p{So})\s*') {
    return ($Subject -replace '^(?::[a-z0-9_+-]+:|\p{So})\s*', '')
  }
  return $Subject
}

function Get-CommitDescriptionLanguage([string]$Subject) {
  $description = Get-CommitDescription $Subject
  if ($description -match '[\u3400-\u4dbf\u4e00-\u9fff]') { return "Chinese" }
  if ($description -match '[A-Za-z]') { return "English" }
  return "Unknown"
}

function Get-CommitLanguageAnalysis {
  [CmdletBinding()]
  param(
    [string[]]$Subjects = @(),
    [ValidateSet("Auto", "Chinese", "English")]
    [string]$PromptLanguage = "Chinese",
    [int]$MinimumSamples = 3,
    [double]$ConfidenceThreshold = 0.6
  )

  if ($MinimumSamples -lt 1) { throw "Commit minimumSamples must be positive" }
  if ($ConfidenceThreshold -le 0 -or $ConfidenceThreshold -gt 1) {
    throw "Commit confidenceThreshold must be greater than 0 and at most 1"
  }

  $counts = [ordered]@{ Chinese = 0; English = 0; Unknown = 0 }
  $examples = [ordered]@{ Chinese = @(); English = @() }
  foreach ($subject in @($Subjects | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) -and [string]$_ -notmatch '^Merge\s' })) {
    $language = Get-CommitDescriptionLanguage ([string]$subject)
    $counts[$language] = [int]$counts[$language] + 1
    if ($language -in @("Chinese", "English") -and @($examples[$language]).Count -lt 2) {
      $examples[$language] = @($examples[$language]) + [string]$subject
    }
  }

  $selectedLanguage = $PromptLanguage
  $reason = "prompt"
  $fallbackUsed = $false
  $confidence = 1.0
  $classifiedCount = [int]$counts.Chinese + [int]$counts.English
  if ($PromptLanguage -eq "Auto") {
    $highest = [Math]::Max([int]$counts.Chinese, [int]$counts.English)
    $confidence = if ($classifiedCount -gt 0) { [Math]::Round(([double]$highest / [double]$classifiedCount), 3) } else { 0.0 }
    if ($classifiedCount -ge $MinimumSamples -and $counts.Chinese -ne $counts.English -and $confidence -ge $ConfidenceThreshold) {
      $selectedLanguage = if ($counts.Chinese -gt $counts.English) { "Chinese" } else { "English" }
      $reason = "repository-history"
    }
    else {
      $selectedLanguage = "English"
      $reason = if ($classifiedCount -lt $MinimumSamples) { "insufficient-samples" } elseif ($counts.Chinese -eq $counts.English) { "mixed-tie" } else { "low-confidence" }
      $fallbackUsed = $true
    }
  }

  return [pscustomobject][ordered]@{
    requestedLanguage = $PromptLanguage
    selectedLanguage = $selectedLanguage
    reason = $reason
    sampleCount = $classifiedCount
    minimumSamples = $MinimumSamples
    confidence = $confidence
    confidenceThreshold = $ConfidenceThreshold
    fallbackUsed = $fallbackUsed
    fallback = "English"
    counts = [pscustomobject]$counts
    examples = [pscustomobject]$examples
  }
}

function Get-RepositoryCommitLanguageAnalysis {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$RepositoryRoot,
    [ValidateSet("Auto", "Chinese", "English")]
    [string]$PromptLanguage = "Chinese",
    $CommitConfig = $null
  )

  $analyzeCount = [int](Get-CommitConfigProperty $CommitConfig "analyzeCount" 30)
  $minimumSamples = [int](Get-CommitConfigProperty $CommitConfig "minimumSamples" 3)
  $confidenceThreshold = [double](Get-CommitConfigProperty $CommitConfig "confidenceThreshold" 0.6)
  if ($analyzeCount -lt 1) { throw "Commit analyzeCount must be positive" }

  $previousPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $subjects = @(& git -C $RepositoryRoot log "-$analyzeCount" --no-merges --pretty=%s 2>&1)
    $exitCode = $LASTEXITCODE
  }
  finally {
    $ErrorActionPreference = $previousPreference
  }
  if ($exitCode -ne 0) {
    throw "Cannot read recent commit subjects: $($subjects -join [Environment]::NewLine)"
  }
  $subjects = @($subjects | Where-Object { $_ -isnot [Management.Automation.ErrorRecord] } | ForEach-Object { [string]$_ })
  return Get-CommitLanguageAnalysis `
    -Subjects $subjects `
    -PromptLanguage $PromptLanguage `
    -MinimumSamples $minimumSamples `
    -ConfidenceThreshold $confidenceThreshold
}

function Assert-CommitSummaryLanguage {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$Summary,
    [Parameter(Mandatory)]
    $Analysis
  )

  if ([string]::IsNullOrWhiteSpace($Summary)) { throw "Summary is required" }
  if ($Summary -match "[`r`n]") { throw "Summary must be one line" }
  $actualLanguage = Get-CommitDescriptionLanguage $Summary
  $expectedLanguage = [string]$Analysis.selectedLanguage
  if ($actualLanguage -ne $expectedLanguage) {
    throw "Summary description language must be $expectedLanguage for PromptLanguage $($Analysis.requestedLanguage); detected $actualLanguage"
  }
}

function Assert-CommitSummaryStyle {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$Summary,
    [Parameter(Mandatory)]
    $Analysis
  )

  $actualStyle = Get-CommitSubjectStyle $Summary
  if ($actualStyle -ne "conventional") {
    throw "Summary must follow Conventional Commits. Expected $($Analysis.expectedFormat); detected $actualStyle"
  }
}

function Select-WorkflowRun {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$Json,

    [Parameter(Mandatory)]
    [string]$Tag,

    [Parameter(Mandatory)]
    [string]$HeadSha
  )

  $parsed = ConvertFrom-Json -InputObject $Json
  foreach ($candidate in $parsed) {
    if ($candidate.headBranch -eq $Tag -and $candidate.headSha -eq $HeadSha) {
      return $candidate
    }
  }
  return $null
}

function Get-WorkflowRunSnapshot {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [object]$Run
  )

  $jobs = @($Run.jobs)
  $failedJobs = @(
    $jobs | Where-Object {
      $_.status -eq "completed" -and
      $_.conclusion -notin @("success", "skipped")
    }
  )
  $jobSignature = @(
    $jobs | Sort-Object name | ForEach-Object {
      "$($_.name):$($_.status):$($_.conclusion)"
    }
  ) -join "|"
  $signature = "$($Run.status):$($Run.conclusion):$jobSignature"

  if ($failedJobs.Count -gt 0) {
    $failed = $failedJobs[0]
    return [pscustomobject]@{
      State = "Failed"
      Signature = $signature
      Message = "Workflow failed: $($failed.name) ($($failed.conclusion))"
    }
  }
  if ($Run.status -eq "completed" -and $Run.conclusion -eq "success") {
    return [pscustomobject]@{
      State = "Succeeded"
      Signature = $signature
      Message = "Workflow completed successfully"
    }
  }
  if ($Run.status -eq "completed") {
    return [pscustomobject]@{
      State = "Failed"
      Signature = $signature
      Message = "Workflow completed with conclusion $($Run.conclusion)"
    }
  }

  $activeJobs = @(
    $jobs |
      Where-Object { $_.status -ne "completed" } |
      ForEach-Object { $_.name }
  )
  return [pscustomobject]@{
    State = "Waiting"
    Signature = $signature
    Message = "Workflow $($Run.status): $($activeJobs -join ', ')"
  }
}

function Test-WorkflowSnapshotChanged {
  [CmdletBinding()]
  param(
    [AllowNull()]
    [string]$PreviousSignature,

    [Parameter(Mandatory)]
    [object]$Snapshot
  )

  return $PreviousSignature -ne $Snapshot.Signature
}

function Assert-ReleaseNotes {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$ReleaseNotes,

    [Parameter(Mandatory)]
    [string]$Heading,

    [int]$MinItems = 2,

    [int]$MaxItems = 6,

    [bool]$RequireChinese = $false
  )

  if ($MinItems -lt 1 -or $MaxItems -lt $MinItems) {
    throw "Invalid release-note item limits"
  }
  $headingPattern = '(?m)^' + [regex]::Escape($Heading) + '\s*$'
  if ($ReleaseNotes -notmatch $headingPattern) {
    throw "Release notes must contain heading: $Heading"
  }
  if ($RequireChinese -and $ReleaseNotes -notmatch '[\u4e00-\u9fff]') {
    throw "Release notes must contain Chinese content"
  }
  $items = [regex]::Matches($ReleaseNotes, '(?m)^-\s+\S.*$')
  if ($items.Count -lt $MinItems -or $items.Count -gt $MaxItems) {
    throw "Release notes must contain $MinItems to $MaxItems key points"
  }
  if ($RequireChinese) {
    foreach ($item in $items) {
      if ($item.Value -notmatch '[\u4e00-\u9fff]') {
        throw "Each release-note key point must contain Chinese"
      }
    }
  }
}

function Stop-ReleaseProcessTree([Diagnostics.Process]$Process) {
  if (-not $Process -or $Process.HasExited) {
    return
  }
  try {
    $taskkillOutput = & "$env:SystemRoot\System32\taskkill.exe" /PID $Process.Id /T /F 2>&1
    if ($LASTEXITCODE -ne 0) {
      $Process.Refresh()
      if (-not $Process.HasExited) {
        throw "taskkill failed for PID $($Process.Id): $($taskkillOutput -join ' ')"
      }
    }
  }
  catch {
    $Process.Refresh()
    if (-not $Process.HasExited) {
      $Process.Kill()
    }
  }
  if (-not $Process.HasExited) {
    if (-not $Process.WaitForExit(5000)) {
      throw "Timed out stopping release process PID $($Process.Id)"
    }
  }
}

function Start-ReleaseProcess($Command, [string]$WorkingDirectory) {
  if (-not $env:ComSpec) {
    throw "Parallel release commands require Windows cmd.exe"
  }

  $commandBytes = [Text.Encoding]::UTF8.GetBytes([string]$Command.command)
  $commandBase64 = [Convert]::ToBase64String($commandBytes)
  $runner =
    '$command = [Text.Encoding]::UTF8.GetString(' +
    '[Convert]::FromBase64String("' + $commandBase64 + '")); ' +
    '& $env:ComSpec /d /s /c $command; exit $LASTEXITCODE'
  $encodedRunner = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($runner))

  $startInfo = [Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = (Get-Process -Id $PID).Path
  $startInfo.Arguments = "-NoProfile -NonInteractive -EncodedCommand $encodedRunner"
  $startInfo.WorkingDirectory = $WorkingDirectory
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true

  $process = [Diagnostics.Process]::new()
  $process.StartInfo = $startInfo
  if (-not $process.Start()) {
    throw "Failed to start $($Command.name)"
  }
  return [pscustomobject]@{
    Name = [string]$Command.name
    Process = $process
    Stdout = $process.StandardOutput.ReadToEndAsync()
    Stderr = $process.StandardError.ReadToEndAsync()
  }
}

function Invoke-ParallelShellChecked {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [object[]]$Commands,

    [Parameter(Mandatory)]
    [string]$WorkingDirectory
  )

  $entries = @()
  $failedEntry = $null

  try {
    foreach ($command in $Commands) {
      $entries += Start-ReleaseProcess -Command $command -WorkingDirectory $WorkingDirectory
    }

    while ($true) {
      foreach ($entry in $entries) {
        if ($entry.Process.HasExited) {
          $entry.Process.WaitForExit()
          if ($entry.Process.ExitCode -ne 0) {
            $failedEntry = $entry
            break
          }
        }
      }
      if ($failedEntry) {
        foreach ($entry in $entries) {
          if ($entry -ne $failedEntry) {
            Stop-ReleaseProcessTree $entry.Process
          }
        }
        break
      }
      if (@($entries | Where-Object { -not $_.Process.HasExited }).Count -eq 0) {
        break
      }
      Start-Sleep -Milliseconds 100
    }

    foreach ($entry in $entries) {
      $entry.Process.WaitForExit()
    }
    if ($failedEntry) {
      $out = $failedEntry.Stdout.Result
      $err = $failedEntry.Stderr.Result
      $separator = [Environment]::NewLine
      throw "$($failedEntry.Name) failed with exit code $($failedEntry.Process.ExitCode):$separator$out$separator$err"
    }
    foreach ($entry in $entries) {
      Write-Host "$($entry.Name) completed"
    }
  }
  finally {
    foreach ($entry in $entries) {
      Stop-ReleaseProcessTree $entry.Process
      $entry.Process.Dispose()
    }
  }
}

function Invoke-SequentialShellChecked {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [object[]]$Commands,

    [Parameter(Mandatory)]
    [string]$WorkingDirectory
  )

  if (-not $env:ComSpec) {
    throw "Release commands require Windows cmd.exe"
  }

  $previousLocation = Get-Location
  try {
    Set-Location -LiteralPath $WorkingDirectory
    foreach ($command in $Commands) {
      Write-Host "Running $($command.name)"
      & $env:ComSpec /d /s /c ([string]$command.command)
      if ($LASTEXITCODE -ne 0) {
        throw "$($command.name) failed with exit code $LASTEXITCODE"
      }
    }
  }
  finally {
    Set-Location -LiteralPath $previousLocation
  }
}
