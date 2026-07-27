# Auto Release contract case: 50-release-e2e.ps1
$releaseRoot = New-TestDirectory "release-e2e"
$releaseRemote = Join-Path ([IO.Path]::GetTempPath()) ("auto-release-release-e2e-remote-" + [guid]::NewGuid().ToString("N"))
$fakeGhRoot = Join-Path ([IO.Path]::GetTempPath()) ("auto-release-fake-gh-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $releaseRemote | Out-Null
New-Item -ItemType Directory -Path $fakeGhRoot | Out-Null
$previousPath = $env:PATH
$previousFakeLog = $env:AUTO_RELEASE_FAKE_GH_LOG
$previousFakeAssetContent = $env:AUTO_RELEASE_FAKE_ASSET_CONTENT
$previousFakeAssetDigest = $env:AUTO_RELEASE_FAKE_ASSET_DIGEST
$previousFakeAssetName = $env:AUTO_RELEASE_FAKE_ASSET_NAME
$previousFakeAssetSize = $env:AUTO_RELEASE_FAKE_ASSET_SIZE
$previousFakeAssetSource = $env:AUTO_RELEASE_FAKE_ASSET_SOURCE
$previousFakeMode = $env:AUTO_RELEASE_FAKE_MODE
$previousFakeCreateMarker = $env:AUTO_RELEASE_FAKE_CREATE_MARKER
$previousFakeWorkflowMarker = $env:AUTO_RELEASE_FAKE_WORKFLOW_MARKER
try {
  & git -C $releaseRemote init --bare | Out-Null
  & git -C $releaseRoot remote add origin $releaseRemote
  & git -C $releaseRoot config user.name "Auto Release E2E"
  & git -C $releaseRoot config user.email "auto-release-e2e@example.invalid"
  Write-TestUtf8 (Join-Path $releaseRoot "package.json") '{"name":"release-e2e","version":"1.0.0"}'
  Write-TestUtf8 (Join-Path $releaseRoot ".gitignore") "dist/`nrelease/`noutput/`n/.codex-release.json`n"
  Write-TestUtf8 (Join-Path $releaseRoot ".codex-release.json") @'
{
  "schemaVersion": 1,
  "projectName": "release-e2e",
  "branch": "main",
  "remote": "origin",
  "githubRepository": "example/release-e2e",
  "tagPrefix": "v",
  "version": {
    "read": {"path":"package.json","pattern":"\\\"version\\\"\\s*:\\s*\\\"(?<version>\\d+\\.\\d+\\.\\d+)\\\""},
    "updates": [
      {"path":"package.json","pattern":"(\\\"version\\\"\\s*:\\s*\\\")\\d+\\.\\d+\\.\\d+(\\\")","replacement":"${1}{version}$2","expectedMatches":1}
    ]
  },
  "prepare": {
    "parallel": false,
    "commands": [{"name":"Build release fixture","command":"if not exist dist mkdir dist && echo binary>dist\\e2e.exe"}],
    "artifacts": [{"source":"dist/e2e.exe","destination":"output/{tag}-portable/e2e.exe","sha256":true}]
  },
  "publish": {
    "workflow": {"name":"Release","event":"push","findTimeoutSeconds":10,"waitTimeoutMinutes":1},
    "release": {
      "mode":"publish-draft",
      "title":"{projectName} {tag}",
      "requireDraft":true,
      "requiredAssets":[{"pattern":"^release-e2e-1\\.1\\.0\\.exe$","label":"E2E executable"}]
    }
  }
}
'@
  Write-TestUtf8 (Join-Path $releaseRoot ".github\workflows\release.yml") @'
# Expected asset: release-e2e-1.1.0.exe
name: Release
on:
  push:
    tags:
      - "v*"
permissions:
  contents: write
jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - run: gh release create "$GITHUB_REF_NAME" release-e2e-1.1.0.exe --draft
'@
  & git -C $releaseRoot add package.json .gitignore .github/workflows/release.yml
  & git -C $releaseRoot commit -m "Initial release E2E fixture" | Out-Null
  & git -C $releaseRoot push --set-upstream origin main | Out-Null

  $fakeGhLog = Join-Path $fakeGhRoot "calls.log"
  $env:AUTO_RELEASE_FAKE_GH_LOG = $fakeGhLog
  $env:AUTO_RELEASE_FAKE_MODE = "publish-draft"
  $env:AUTO_RELEASE_FAKE_ASSET_NAME = "release-e2e-1.1.0.exe"
  $env:AUTO_RELEASE_FAKE_ASSET_CONTENT = "release-binary"
  $env:AUTO_RELEASE_FAKE_ASSET_SOURCE = ""
  $env:AUTO_RELEASE_FAKE_ASSET_SIZE = "14"
  $assetBytes = [Text.UTF8Encoding]::new($false).GetBytes($env:AUTO_RELEASE_FAKE_ASSET_CONTENT)
  $assetHasher = [Security.Cryptography.SHA256]::Create()
  try { $env:AUTO_RELEASE_FAKE_ASSET_DIGEST = ([BitConverter]::ToString($assetHasher.ComputeHash($assetBytes))).Replace("-", "").ToLowerInvariant() }
  finally { $assetHasher.Dispose() }
  $env:AUTO_RELEASE_FAKE_WORKFLOW_MARKER = Join-Path $fakeGhRoot "workflow-failed-once"
  Write-TestUtf8 (Join-Path $fakeGhRoot "gh.ps1") @'
$safeArgs = @($args | ForEach-Object { ([string]$_).Replace("`r", "\r").Replace("`n", "\n") })
$commandLine = $safeArgs -join " "
Add-Content -LiteralPath $env:AUTO_RELEASE_FAKE_GH_LOG -Value $commandLine
if ($args[0] -eq "auth" -and $args[1] -eq "status") { exit 0 }
if ($args[0] -eq "run" -and $args[1] -eq "list") {
  $sha = (& git rev-parse HEAD).Trim()
  $tag = @(& git tag --points-at HEAD | Where-Object { $_ }) | Sort-Object | Select-Object -Last 1
  '[{"databaseId":7001,"headBranch":"' + $tag + '","headSha":"' + $sha + '","status":"completed","url":"https://example.invalid/runs/7001"}]'
  exit 0
}
if ($args[0] -eq "run" -and $args[1] -eq "view") {
  if (-not (Test-Path -LiteralPath $env:AUTO_RELEASE_FAKE_WORKFLOW_MARKER)) {
    [IO.File]::WriteAllText($env:AUTO_RELEASE_FAKE_WORKFLOW_MARKER, "failed")
    '{"status":"completed","conclusion":"failure","url":"https://example.invalid/runs/7001","jobs":[{"name":"Build","status":"completed","conclusion":"failure"}]}'
    exit 0
  }
  '{"status":"completed","conclusion":"success","url":"https://example.invalid/runs/7001","jobs":[{"name":"Build","status":"completed","conclusion":"success"}]}'
  exit 0
}
if ($args[0] -eq "release" -and $args[1] -eq "view") {
  if ($env:AUTO_RELEASE_FAKE_MODE -eq "create" -and -not (Test-Path -LiteralPath $env:AUTO_RELEASE_FAKE_CREATE_MARKER)) { exit 1 }
  '{"isDraft":true,"url":"https://example.invalid/releases/' + $args[2] + '","assets":[{"name":"' + $env:AUTO_RELEASE_FAKE_ASSET_NAME + '","size":' + $env:AUTO_RELEASE_FAKE_ASSET_SIZE + ',"state":"uploaded","digest":"sha256:' + $env:AUTO_RELEASE_FAKE_ASSET_DIGEST + '"}]}'
  exit 0
}
if ($args[0] -eq "release" -and $args[1] -eq "create") {
  if ($env:AUTO_RELEASE_FAKE_MODE -ne "create") { throw "Unexpected release create in publish-draft mode" }
  [IO.File]::WriteAllText($env:AUTO_RELEASE_FAKE_CREATE_MARKER, "created")
  exit 0
}
if ($args[0] -eq "release" -and $args[1] -eq "download") {
  $dirIndex = [Array]::IndexOf([object[]]$args, "--dir")
  if ($dirIndex -lt 0) { throw "Fake release download did not receive --dir" }
  $destination = Join-Path $args[$dirIndex + 1] $env:AUTO_RELEASE_FAKE_ASSET_NAME
  if ($env:AUTO_RELEASE_FAKE_ASSET_SOURCE) {
    Copy-Item -LiteralPath $env:AUTO_RELEASE_FAKE_ASSET_SOURCE -Destination $destination
  }
  else {
    [IO.File]::WriteAllText($destination, $env:AUTO_RELEASE_FAKE_ASSET_CONTENT, [Text.UTF8Encoding]::new($false))
  }
  exit 0
}
if ($args[0] -eq "release" -and $args[1] -eq "edit") { exit 0 }
throw "Unexpected fake gh command: $commandLine"
'@
  $env:PATH = "$fakeGhRoot;$previousPath"
  Assert-Equal (Get-Command gh).Source (Join-Path $fakeGhRoot "gh.ps1") "Fake GitHub CLI was not selected"

  $summary = "chore(release): $newLabel release end to end"
  $previewOutput = & $shell -NoProfile -ExecutionPolicy Bypass -File $invokeScript `
    -Operation Release -Version v1.1.0 -PromptLanguage Chinese -Summary $summary -ReleaseNotes $validNotes `
    -RepositoryRoot $releaseRoot -WhatIf -OutputFormat Json
  if ($LASTEXITCODE -ne 0) { throw "Release WhatIf process failed" }
  $preview = ($previewOutput | Select-Object -Last 1) | ConvertFrom-Json
  Assert-Equal $preview.status "planned" "Release WhatIf did not return a plan"
  Assert-Equal $preview.whatIf $true "Release WhatIf JSON is missing the whatIf marker"
  Assert-Equal $preview.commitStyle.selectedStyle "conventional" "Release WhatIf did not report the selected commit style"
  Assert-Equal $preview.commitLanguage.selectedLanguage "Chinese" "Release WhatIf did not report the prompt language"
  Assert-Equal ((Get-Content -Raw -Encoding UTF8 (Join-Path $releaseRoot "package.json") | ConvertFrom-Json).version) "1.0.0" "Release WhatIf changed the project version"
  if (git -C $releaseRoot tag) { throw "Release WhatIf created a tag" }

  $savedPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $firstReleaseOutput = & $shell -NoProfile -ExecutionPolicy Bypass -File $invokeScript `
      -Operation Release -Version v1.1.0 -PromptLanguage Chinese -Summary $summary -ReleaseNotes $validNotes `
      -RepositoryRoot $releaseRoot -OutputFormat Json 2>&1
    $firstReleaseExitCode = $LASTEXITCODE
  }
  finally {
    $ErrorActionPreference = $savedPreference
  }
  if ($firstReleaseExitCode -eq 0) { throw "Release resume fixture did not fail after the first tag push" }
  $firstReleaseResult = @($firstReleaseOutput | Where-Object { $_ -isnot [Management.Automation.ErrorRecord] } | ForEach-Object { [string]$_ } | Where-Object { $_.StartsWith("{") })[-1] | ConvertFrom-Json
  Assert-Equal $firstReleaseResult.stage "Publish" "Release resume fixture failed in the wrong stage"
  if (-not (git -C $releaseRoot ls-remote origin refs/tags/v1.1.0)) { throw "Failed Release did not preserve the remote tag for resume" }
  if ((Get-Content -Raw -Encoding UTF8 $fakeGhLog) -match 'release edit v1\.1\.0') { throw "Failed workflow unexpectedly published the draft Release" }

  & $invokeScript -Operation Release -Version v1.1.0 -PromptLanguage Chinese -Summary $summary -ReleaseNotes $validNotes -RepositoryRoot $releaseRoot
  Assert-Equal ((Get-Content -Raw -Encoding UTF8 (Join-Path $releaseRoot "package.json") | ConvertFrom-Json).version) "1.1.0" "Release E2E did not update the version"
  if (-not (Test-Path -LiteralPath (Join-Path $releaseRoot "output\release-e2e.exe") -PathType Leaf)) {
    throw "Release E2E did not create the canonical versionless local output"
  }
  if (Test-Path -LiteralPath (Join-Path $releaseRoot "output\v1.1.0-portable")) {
    throw "Release E2E created a versioned local output directory"
  }
  $localReleaseHead = git -C $releaseRoot rev-parse HEAD
  $remoteReleaseHead = (git -C $releaseRoot ls-remote origin refs/heads/main).Split("`t")[0]
  Assert-Equal $remoteReleaseHead $localReleaseHead "Release E2E did not push the release commit"
  if (-not (git -C $releaseRoot ls-remote origin refs/tags/v1.1.0)) { throw "Release E2E did not push the tag" }
  $fakeGhCalls = @(Get-Content -Encoding UTF8 $fakeGhLog)
  Assert-Match ($fakeGhCalls -join "`n") 'release download v1\.1\.0' "Release E2E did not download assets for SHA256 verification"
  Assert-Match ($fakeGhCalls -join "`n") 'release edit v1\.1\.0.*--verify-tag.*--repo example/release-e2e' "Release E2E did not verify the tag while publishing the draft"
  foreach ($call in @($fakeGhCalls | Where-Object { $_ -match '^(?:run|release) ' })) {
    Assert-Match $call '--repo example/release-e2e' "GitHub command was not bound to the configured repository"
  }
  Assert-Equal (git -C $releaseRoot status --porcelain) $null "Release E2E left a dirty working tree"

  $createConfigPath = Join-Path $releaseRoot ".codex-release.json"
  $createConfig = Get-Content -Raw -Encoding UTF8 $createConfigPath | ConvertFrom-Json
  $createConfig.publish.release.mode = "create"
  $createConfig.publish.release | Add-Member -NotePropertyName uploadAssets -NotePropertyValue @("dist/e2e.exe")
  $createConfig.publish.release.requiredAssets = @([pscustomobject]@{ pattern = "^e2e\.exe$"; label = "Uploaded executable" })
  Write-TestUtf8 $createConfigPath (($createConfig | ConvertTo-Json -Depth 20) + "`n")
  $createWorkflowPath = Join-Path $releaseRoot ".github\workflows\release.yml"
  $createWorkflow = (Get-Content -Raw -Encoding UTF8 $createWorkflowPath).Replace("release-e2e-1.1.0.exe", "e2e.exe")
  Write-TestUtf8 $createWorkflowPath $createWorkflow
  $env:AUTO_RELEASE_FAKE_MODE = "create"
  $env:AUTO_RELEASE_FAKE_CREATE_MARKER = Join-Path $fakeGhRoot "create-release-exists"
  $env:AUTO_RELEASE_FAKE_ASSET_NAME = "e2e.exe"
  $env:AUTO_RELEASE_FAKE_ASSET_SOURCE = Join-Path $releaseRoot "dist\e2e.exe"
  $createAsset = Get-Item -LiteralPath $env:AUTO_RELEASE_FAKE_ASSET_SOURCE
  $env:AUTO_RELEASE_FAKE_ASSET_SIZE = [string]$createAsset.Length
  $env:AUTO_RELEASE_FAKE_ASSET_DIGEST = (Get-FileHash -Algorithm SHA256 -LiteralPath $createAsset.FullName).Hash.ToLowerInvariant()
  $createSummary = "chore(release): $newLabel draft first create mode"
  $createNotes = $validNotes.Replace("release", "create")
  & $invokeScript -Operation Release -Version v1.2.0 -PromptLanguage Chinese -Summary $createSummary -ReleaseNotes $createNotes -RepositoryRoot $releaseRoot
  $createCalls = @(Get-Content -Encoding UTF8 $fakeGhLog) -join "`n"
  Assert-Match $createCalls 'release create v1\.2\.0.*--draft --verify-tag --repo example/release-e2e' "Create mode did not create a repository-bound draft first"
  Assert-Match $createCalls 'release download v1\.2\.0.*--repo example/release-e2e' "Create mode did not verify the uploaded draft asset"
  Assert-Match $createCalls 'release edit v1\.2\.0.*--draft=false --verify-tag --repo example/release-e2e' "Create mode did not publish only after verification"

  $errorOutput = & $shell -NoProfile -ExecutionPolicy Bypass -File $invokeScript `
    -Operation CommitPush -RepositoryRoot $releaseRoot -OutputFormat Json 2>$null
  if ($LASTEXITCODE -eq 0) { throw "JSON failure fixture unexpectedly succeeded" }
  $errorResult = ($errorOutput | Select-Object -Last 1) | ConvertFrom-Json
  Assert-Equal $errorResult.status "failed" "JSON failure output has the wrong status"
  Assert-Match $errorResult.errorCode '^AUTO_RELEASE_[A-Z]+_FAILED$' "JSON failure output lacks a stable error code"
}
finally {
  $env:PATH = $previousPath
  $env:AUTO_RELEASE_FAKE_GH_LOG = $previousFakeLog
  $env:AUTO_RELEASE_FAKE_ASSET_CONTENT = $previousFakeAssetContent
  $env:AUTO_RELEASE_FAKE_ASSET_DIGEST = $previousFakeAssetDigest
  $env:AUTO_RELEASE_FAKE_ASSET_NAME = $previousFakeAssetName
  $env:AUTO_RELEASE_FAKE_ASSET_SIZE = $previousFakeAssetSize
  $env:AUTO_RELEASE_FAKE_ASSET_SOURCE = $previousFakeAssetSource
  $env:AUTO_RELEASE_FAKE_MODE = $previousFakeMode
  $env:AUTO_RELEASE_FAKE_CREATE_MARKER = $previousFakeCreateMarker
  $env:AUTO_RELEASE_FAKE_WORKFLOW_MARKER = $previousFakeWorkflowMarker
  Remove-TestDirectory $releaseRoot
  Remove-TestDirectory $releaseRemote
  Remove-TestDirectory $fakeGhRoot
}
