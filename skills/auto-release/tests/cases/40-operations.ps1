# Auto Release contract case: 40-operations.ps1
$operationsRoot = New-TestDirectory "operations"
$operationsRemote = Join-Path ([IO.Path]::GetTempPath()) ("auto-release-operations-remote-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $operationsRemote | Out-Null
try {
  & git -C $operationsRemote init --bare | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "operations bare remote init failed" }
  & git -C $operationsRoot remote add origin $operationsRemote
  & git -C $operationsRoot config user.name "Project Release Test"
  & git -C $operationsRoot config user.email "auto-release@example.invalid"
  Write-TestUtf8 (Join-Path $operationsRoot "package.json") '{"name":"local-app","version":"1.0.0"}'
  Write-TestUtf8 (Join-Path $operationsRoot "source.txt") "initial`n"
  Write-TestUtf8 (Join-Path $operationsRoot ".gitignore") "dist/`n/.codex-release.json`n"
  Write-TestUtf8 (Join-Path $operationsRoot ".codex-release.json") @'
{
  "schemaVersion": 1,
  "projectName": "local-app",
  "branch": "main",
  "remote": "origin",
  "tagPrefix": "v",
  "version": {
    "read": {
      "path": "package.json",
      "pattern": "\\\"version\\\"\\s*:\\s*\\\"(?<version>\\d+\\.\\d+\\.\\d+)\\\""
    },
    "updates": [
      {
        "path": "package.json",
        "pattern": "(\\\"version\\\"\\s*:\\s*\\\")\\d+\\.\\d+\\.\\d+(\\\")",
        "replacement": "${1}{version}$2",
        "expectedMatches": 1
      }
    ]
  },
  "prepare": {
    "parallel": false,
    "bootstrapInputs": ["package.json"],
    "bootstrapCommands": [
      {"name":"Bootstrap once","command":"if exist bootstrap-count.txt (echo twice>bootstrap-count.txt) else (echo once>bootstrap-count.txt)"}
    ],
    "localCommands": [
      {"name":"Build local program","command":"if not exist dist mkdir dist && echo local>dist\\local-app.exe"}
    ],
    "commands": [
      {"name":"Build release program","command":"if not exist dist mkdir dist && echo release>dist\\local-app.exe"}
    ],
    "artifacts": [
      {
        "source":"dist/local-app.exe",
        "destination":"release/{tag}/local-app.exe",
        "sha256":true
      }
    ]
  },
  "publish": {
    "workflow": {
      "name": "Release",
      "event": "push",
      "findTimeoutSeconds": 1,
      "waitTimeoutMinutes": 1
    },
    "release": {"mode":"none"}
  }
}
'@
  Write-TestUtf8 (Join-Path $operationsRoot ".github\workflows\release.yml") @'
name: Manual workflow without tag trigger
on: workflow_dispatch
jobs: {}
'@
  & git -C $operationsRoot add package.json source.txt .gitignore .github/workflows/release.yml
  & git -C $operationsRoot commit -m "Initial operations fixture" | Out-Null
  & git -C $operationsRoot push --set-upstream origin main | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "operations initial push failed" }

  & $invokeScript -Operation LocalBuild -RepositoryRoot $operationsRoot
  $localPackage = Get-Content -Raw -Encoding UTF8 (Join-Path $operationsRoot "package.json") | ConvertFrom-Json
  Assert-Equal $localPackage.version "1.0.0" "LocalBuild changed the project version"
  if (-not (Test-Path -LiteralPath (Join-Path $operationsRoot "dist\local-app.exe") -PathType Leaf)) { throw "LocalBuild did not build the local program" }
  $unifiedLocalProgram = Join-Path $operationsRoot "output\local-app.exe"
  if (-not (Test-Path -LiteralPath $unifiedLocalProgram -PathType Leaf)) { throw "LocalBuild did not create the unified local output" }
  Assert-Equal (Get-Content -Raw -Encoding UTF8 $unifiedLocalProgram).Trim() "local" "Unified local output has the wrong content"
  Assert-Equal (Get-Content -Raw -Encoding UTF8 (Join-Path $operationsRoot "bootstrap-count.txt")).Trim() "once" "LocalBuild did not run the initial dependency bootstrap"
  if (Test-Path -LiteralPath (Join-Path $operationsRoot "release\v1.0.0\local-app.exe")) {
    throw "LocalBuild incorrectly used the versioned release destination"
  }
  if (-not (Test-Path -LiteralPath (Join-Path $operationsRoot ".git\auto-release\local-build.json") -PathType Leaf)) { throw "LocalBuild did not record a build receipt" }
  $localReceipt = Get-Content -Raw -Encoding UTF8 (Join-Path $operationsRoot ".git\auto-release\local-build.json") | ConvertFrom-Json
  Assert-Equal $localReceipt.artifacts[0].path "output/local-app.exe" "Local build receipt did not record the unified output"

  $staleManagedProgram = Join-Path $operationsRoot "output\local-app-old.exe"
  Copy-Item -LiteralPath $unifiedLocalProgram -Destination $staleManagedProgram
  $localReceipt.artifacts += [pscustomobject]@{
    path = "output/local-app-old.exe"
    sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $staleManagedProgram).Hash
  }
  Write-TestUtf8 (Join-Path $operationsRoot ".git\auto-release\local-build.json") (($localReceipt | ConvertTo-Json -Depth 10) + "`n")

  $lockingProcess = $null
  $unrelatedProcess = $null
  try {
    Copy-Item -LiteralPath (Join-Path $env:WINDIR "System32\PING.EXE") -Destination $unifiedLocalProgram -Force
    $unrelatedProgram = Join-Path $operationsRoot "output\unrelated.exe"
    Copy-Item -LiteralPath (Join-Path $env:WINDIR "System32\PING.EXE") -Destination $unrelatedProgram -Force
    $lockingProcess = Start-Process -FilePath $unifiedLocalProgram -ArgumentList @("-n", "60", "127.0.0.1") -WindowStyle Hidden -PassThru
    $unrelatedProcess = Start-Process -FilePath $unrelatedProgram -ArgumentList @("-n", "60", "127.0.0.1") -WindowStyle Hidden -PassThru
    Start-Sleep -Milliseconds 500
    $lockingProcess.Refresh()
    $unrelatedProcess.Refresh()
    if ($lockingProcess.HasExited) { throw "Locking fixture process exited before LocalBuild" }
    if ($unrelatedProcess.HasExited) { throw "Unrelated fixture process exited before LocalBuild" }

    & $invokeScript -Operation LocalBuild -RepositoryRoot $operationsRoot
    $lockingProcess.Refresh()
    $unrelatedProcess.Refresh()
    if (-not $lockingProcess.HasExited) { throw "LocalBuild did not stop the process using the unified output" }
    if ($unrelatedProcess.HasExited) { throw "LocalBuild stopped an unrelated executable from the output directory" }
    Assert-Equal (Get-Content -Raw -Encoding UTF8 $unifiedLocalProgram).Trim() "local" "LocalBuild did not overwrite the unlocked canonical output"
    Assert-Equal (Get-Content -Raw -Encoding UTF8 (Join-Path $operationsRoot "bootstrap-count.txt")).Trim() "once" "LocalBuild reran unchanged dependency bootstrap commands"
    if (Test-Path -LiteralPath $staleManagedProgram) { throw "LocalBuild did not remove a stale managed artifact" }
    $updatedReceipt = Get-Content -Raw -Encoding UTF8 (Join-Path $operationsRoot ".git\auto-release\local-build.json") | ConvertFrom-Json
    Assert-Equal (@($updatedReceipt.artifacts).Count) 1 "Local build receipt included stale or unrelated output files"
    Assert-Equal $updatedReceipt.artifacts[0].path "output/local-app.exe" "Local build receipt did not use the exact artifact manifest"
    if (Test-Path -LiteralPath (Join-Path $operationsRoot "output\local-app-2.exe")) {
      throw "LocalBuild created a numeric fallback instead of replacing the occupied canonical output"
    }
  }
  finally {
    if ($lockingProcess) {
      $lockingProcess.Refresh()
      if (-not $lockingProcess.HasExited) {
        Stop-Process -Id $lockingProcess.Id -Force -ErrorAction SilentlyContinue
      }
    }
    if ($unrelatedProcess) {
      $unrelatedProcess.Refresh()
      if (-not $unrelatedProcess.HasExited) {
        Stop-Process -Id $unrelatedProcess.Id -Force -ErrorAction SilentlyContinue
      }
    }
  }

  $reuseReceiptTimestamp = [DateTime]::Parse(
    [string](Get-Content -Raw -Encoding UTF8 (Join-Path $operationsRoot ".git\auto-release\local-build.json") | ConvertFrom-Json).builtAtUtc
  )
  Start-Sleep -Milliseconds 1100
  & $invokeScript -Operation LocalBuild -RepositoryRoot $operationsRoot
  $afterReuseTimestamp = [DateTime]::Parse(
    [string](Get-Content -Raw -Encoding UTF8 (Join-Path $operationsRoot ".git\auto-release\local-build.json") | ConvertFrom-Json).builtAtUtc
  )
  Assert-Equal $afterReuseTimestamp $reuseReceiptTimestamp "LocalBuild did not reuse a fresh verified output"
  $localJsonOutput = & $shell -NoProfile -ExecutionPolicy Bypass -File $invokeScript `
    -Operation LocalBuild -RepositoryRoot $operationsRoot -OutputFormat Json
  if ($LASTEXITCODE -ne 0) { throw "LocalBuild JSON process failed" }
  $localJson = ($localJsonOutput | Select-Object -Last 1) | ConvertFrom-Json
  Assert-Equal $localJson.status "succeeded" "LocalBuild JSON has the wrong status"
  Assert-Equal $localJson.reused $true "LocalBuild JSON did not report reuse"
  Assert-Equal (@($localJson.artifacts).Count) 1 "LocalBuild JSON did not report its artifact"
  Start-Sleep -Milliseconds 1100
  & $invokeScript -Operation LocalBuild -RepositoryRoot $operationsRoot -ForceRebuild
  $afterForceTimestamp = [DateTime]::Parse(
    [string](Get-Content -Raw -Encoding UTF8 (Join-Path $operationsRoot ".git\auto-release\local-build.json") | ConvertFrom-Json).builtAtUtc
  )
  if ($afterForceTimestamp -le $reuseReceiptTimestamp) {
    throw "ForceRebuild did not rebuild the local output"
  }

  Remove-Item -LiteralPath (Join-Path $operationsRoot "dist\local-app.exe") -Force
  & $script -Mode Prepare -Version v1.1.0 -Summary "Skip local build test" -RepositoryRoot $operationsRoot -SkipBuild
  if (Test-Path -LiteralPath (Join-Path $operationsRoot "dist\local-app.exe")) { throw "Prepare SkipBuild still ran build commands" }
  $preparedPackage = Get-Content -Raw -Encoding UTF8 (Join-Path $operationsRoot "package.json") | ConvertFrom-Json
  Assert-Equal $preparedPackage.version "1.1.0" "Prepare SkipBuild did not update the release version"
  Remove-Item -LiteralPath (Join-Path $operationsRoot "output") -Recurse -Force

  Add-Content -Encoding UTF8 -LiteralPath (Join-Path $operationsRoot "source.txt") -Value "unstaged"
  Write-TestUtf8 (Join-Path $operationsRoot "staged.txt") "staged`n"
  & git -C $operationsRoot add staged.txt
  Write-TestUtf8 (Join-Path $operationsRoot "untracked.txt") "untracked`n"
  $commitSummary = "chore: $newLabel operations changes"
  & $invokeScript -Operation CommitPush -PromptLanguage Chinese -Summary $commitSummary -RepositoryRoot $operationsRoot
  Assert-Equal (git -C $operationsRoot log -1 --pretty=%s) $commitSummary "CommitPush used the wrong commit summary"
  Assert-Equal (git -C $operationsRoot status --porcelain) $null "CommitPush did not commit all changes"
  $localHead = git -C $operationsRoot rev-parse HEAD
  $remoteHead = (git -C $operationsRoot ls-remote origin refs/heads/main).Split("`t")[0]
  Assert-Equal $remoteHead $localHead "CommitPush did not push the current branch"

  Write-TestUtf8 (Join-Path $operationsRoot "english-language.txt") "language`n"
  $englishPreviewOutput = & $shell -NoProfile -ExecutionPolicy Bypass -File $invokeScript `
    -Operation CommitPush -PromptLanguage English -Summary "docs: document prompt language" `
    -RepositoryRoot $operationsRoot -WhatIf -OutputFormat Json
  if ($LASTEXITCODE -ne 0) { throw "English CommitPush WhatIf process failed" }
  $englishPreview = ($englishPreviewOutput | Select-Object -Last 1) | ConvertFrom-Json
  Assert-Equal $englishPreview.commitLanguage.selectedLanguage "English" "CommitPush preview ignored the English prompt language"
  Assert-Throws {
    & $invokeScript -Operation CommitPush -PromptLanguage English -Summary $commitSummary -RepositoryRoot $operationsRoot -WhatIf
  } "must be English" "English CommitPush accepted a Chinese description"
  Remove-Item -LiteralPath (Join-Path $operationsRoot "english-language.txt") -Force

  $localConfigPath = Join-Path $operationsRoot ".codex-release.json"
  $localConfigHashBeforeMigration = (Get-FileHash -Algorithm SHA256 -LiteralPath $localConfigPath).Hash
  & git -C $operationsRoot add -f -- .codex-release.json
  & git -C $operationsRoot commit -m "chore: add legacy local config fixture" | Out-Null
  & git -C $operationsRoot push origin main | Out-Null
  Assert-Throws {
    & $invokeScript -Operation CommitPush -Summary $commitSummary -RepositoryRoot $operationsRoot -WhatIf
  } "local release config is still tracked" "CommitPush preview accepted a tracked local config"
  & git -C $operationsRoot rm --cached -- .codex-release.json | Out-Null
  Write-TestUtf8 (Join-Path $operationsRoot "migration-note.txt") "migration`n"
  $migrationBase = git -C $operationsRoot rev-parse HEAD
  $migrationPlanPath = Join-Path $operationsRoot ".git\auto-release\migration-plan.json"
  $migrationPlan = [pscustomobject][ordered]@{
    schemaVersion = 1
    baseHead = $migrationBase
    groups = @(
      [pscustomobject][ordered]@{ summary = "chore: $newLabel stop tracking local config"; paths = @(".codex-release.json") },
      [pscustomobject][ordered]@{ summary = "docs: $newLabel document local config migration"; paths = @("migration-note.txt") }
    )
  }
  Write-TestUtf8 $migrationPlanPath (($migrationPlan | ConvertTo-Json -Depth 10) + "`n")
  & $invokeScript -Operation CommitPush -CommitStrategy AutoSplit -CommitPlanPath $migrationPlanPath -RepositoryRoot $operationsRoot
  if (@(git -C $operationsRoot ls-files -- .codex-release.json).Count -gt 0) { throw "AutoSplit migration kept the local config tracked" }
  if (-not (Test-Path -LiteralPath $localConfigPath -PathType Leaf)) { throw "AutoSplit migration removed the local config from disk" }
  Assert-Equal (Get-FileHash -Algorithm SHA256 -LiteralPath $localConfigPath).Hash $localConfigHashBeforeMigration "AutoSplit migration changed the local config"
  $localHead = git -C $operationsRoot rev-parse HEAD

  $multiBase = $localHead
  Write-TestUtf8 (Join-Path $operationsRoot "docs\usage.md") "usage`n"
  Write-TestUtf8 (Join-Path $operationsRoot "src\feature.txt") "feature`n"
  $multiPlanPath = Join-Path $operationsRoot ".git\auto-release\commit-plan.json"
  $multiPlan = [pscustomobject][ordered]@{
    schemaVersion = 1
    baseHead = $multiBase
    groups = @(
      [pscustomobject][ordered]@{
        summary = "docs: $newLabel usage documentation"
        paths = @("docs/usage.md")
      },
      [pscustomobject][ordered]@{
        summary = "feat: $newLabel grouped feature"
        paths = @("src/feature.txt")
      }
    )
  }
  Write-TestUtf8 $multiPlanPath (($multiPlan | ConvertTo-Json -Depth 10) + "`n")
  $mixedLanguagePlan = [pscustomobject][ordered]@{
    schemaVersion = 1
    baseHead = $multiBase
    groups = @(
      $multiPlan.groups[0],
      [pscustomobject][ordered]@{ summary = "feat: add grouped feature"; paths = @("src/feature.txt") }
    )
  }
  Write-TestUtf8 $multiPlanPath (($mixedLanguagePlan | ConvertTo-Json -Depth 10) + "`n")
  Assert-Throws {
    & $invokeScript -Operation CommitPush -CommitStrategy AutoSplit -PromptLanguage Chinese -CommitPlanPath $multiPlanPath -RepositoryRoot $operationsRoot -WhatIf
  } "must be Chinese" "AutoSplit accepted mixed commit-description languages"
  Write-TestUtf8 $multiPlanPath (($multiPlan | ConvertTo-Json -Depth 10) + "`n")
  $multiPreviewOutput = & $shell -NoProfile -ExecutionPolicy Bypass -File $invokeScript `
    -Operation CommitPush -CommitStrategy AutoSplit -PromptLanguage Chinese -CommitPlanPath $multiPlanPath `
    -RepositoryRoot $operationsRoot -WhatIf -OutputFormat Json
  if ($LASTEXITCODE -ne 0) { throw "AutoSplit WhatIf process failed" }
  $multiPreview = ($multiPreviewOutput | Select-Object -Last 1) | ConvertFrom-Json
  Assert-Equal $multiPreview.commitStrategy "AutoSplit" "AutoSplit WhatIf reported the wrong strategy"
  Assert-Equal $multiPreview.commitLanguage.selectedLanguage "Chinese" "AutoSplit WhatIf ignored the prompt language"
  Assert-Equal @($multiPreview.commitPlan.groups).Count 2 "AutoSplit WhatIf did not return both commit groups"
  Assert-Equal (git -C $operationsRoot rev-parse HEAD) $multiBase "AutoSplit WhatIf created a commit"

  $multiOutput = & $shell -NoProfile -ExecutionPolicy Bypass -File $invokeScript `
    -Operation CommitPush -CommitStrategy AutoSplit -PromptLanguage Chinese -CommitPlanPath $multiPlanPath `
    -RepositoryRoot $operationsRoot -OutputFormat Json
  if ($LASTEXITCODE -ne 0) { throw "AutoSplit CommitPush process failed" }
  $multiResult = ($multiOutput | Select-Object -Last 1) | ConvertFrom-Json
  Assert-Equal $multiResult.commitCount 2 "AutoSplit did not report both commits"
  $multiSubjects = @(git -C $operationsRoot log -2 --pretty=%s)
  Assert-Equal $multiSubjects[1] $multiPlan.groups[0].summary "AutoSplit created the first commit in the wrong order"
  Assert-Equal $multiSubjects[0] $multiPlan.groups[1].summary "AutoSplit created the second commit in the wrong order"
  Assert-Equal (git -C $operationsRoot status --porcelain) $null "AutoSplit left a dirty working tree"
  Assert-Equal (git -C $operationsRoot branch --list "auto-release/transaction-*") $null "AutoSplit left a transaction branch"
  $multiHead = git -C $operationsRoot rev-parse HEAD
  $remoteMultiHead = (git -C $operationsRoot ls-remote origin refs/heads/main).Split("`t")[0]
  Assert-Equal $remoteMultiHead $multiHead "AutoSplit did not push the complete commit chain"

  Write-TestUtf8 (Join-Path $operationsRoot "safe.txt") "safe`n"
  Write-TestUtf8 (Join-Path $operationsRoot "bad.txt") "bad   `n"
  & git -C $operationsRoot add safe.txt
  $rollbackPlan = [pscustomobject][ordered]@{
    schemaVersion = 1
    baseHead = $multiHead
    groups = @(
      [pscustomobject][ordered]@{ summary = "chore: $newLabel safe change"; paths = @("safe.txt") },
      [pscustomobject][ordered]@{ summary = "test: $newLabel invalid whitespace"; paths = @("bad.txt") }
    )
  }
  Write-TestUtf8 $multiPlanPath (($rollbackPlan | ConvertTo-Json -Depth 10) + "`n")
  Assert-Throws {
    & $invokeScript -Operation CommitPush -CommitStrategy AutoSplit -CommitPlanPath $multiPlanPath -RepositoryRoot $operationsRoot
  } "trailing whitespace" "AutoSplit accepted a failing later commit group"
  Assert-Equal (git -C $operationsRoot branch --show-current) "main" "AutoSplit rollback left the transaction branch checked out"
  Assert-Equal (git -C $operationsRoot rev-parse HEAD) $multiHead "AutoSplit rollback changed the original branch"
  Assert-Match (git -C $operationsRoot diff --cached --name-only) '^safe\.txt$' "AutoSplit rollback did not restore the original index"
  Assert-Match (git -C $operationsRoot status --porcelain) '\?\? bad\.txt' "AutoSplit rollback lost an untracked file"
  Assert-Equal (git -C $operationsRoot branch --list "auto-release/transaction-*") $null "AutoSplit rollback left a transaction branch"
  & git -C $operationsRoot reset -- safe.txt | Out-Null
  Remove-Item -LiteralPath (Join-Path $operationsRoot "safe.txt"), (Join-Path $operationsRoot "bad.txt") -Force

  $mainHead = $multiHead
  & git -C $operationsRoot switch -c feature/commit-push | Out-Null
  Write-TestUtf8 (Join-Path $operationsRoot "feature.txt") "feature`n"
  $featureSummary = "chore: $newLabel feature branch"
  & $invokeScript -Operation CommitPush -Summary $featureSummary -RepositoryRoot $operationsRoot
  $featureHead = git -C $operationsRoot rev-parse HEAD
  $remoteFeatureHead = (git -C $operationsRoot ls-remote origin refs/heads/feature/commit-push).Split("`t")[0]
  Assert-Equal $remoteFeatureHead $featureHead "CommitPush used the configured release branch instead of the current branch"
  $remoteMainHead = (git -C $operationsRoot ls-remote origin refs/heads/main).Split("`t")[0]
  Assert-Equal $remoteMainHead $mainHead "CommitPush unexpectedly changed the configured release branch"

  Write-TestUtf8 (Join-Path $operationsRoot ".env") "TOKEN=secret`n"
  Assert-Throws {
    & $invokeScript -Operation CommitPush -Summary $commitSummary -RepositoryRoot $operationsRoot
  } "possible secret file" "CommitPush accepted a possible secret file"
  & git -C $operationsRoot diff --cached --quiet
  if ($LASTEXITCODE -ne 0) { throw "Secret rejection did not restore the original index" }
}
finally {
  Remove-TestDirectory $operationsRoot
  Remove-TestDirectory $operationsRemote
}
