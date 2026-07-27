# Auto Release contract case: 10-release-runner.ps1
$planRoot = Join-Path ([IO.Path]::GetTempPath()) ("auto-release-plan-" + [guid]::NewGuid().ToString("N"))
$bareRoot = Join-Path ([IO.Path]::GetTempPath()) ("auto-release-remote-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $planRoot | Out-Null
New-Item -ItemType Directory -Path $bareRoot | Out-Null
try {
  & git -C $planRoot init --initial-branch=main | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "git init failed" }
  & git -C $bareRoot init --bare | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "bare git init failed" }
  & git -C $planRoot remote add origin $bareRoot
  if ($LASTEXITCODE -ne 0) { throw "git remote add failed" }
  [IO.File]::WriteAllText(
    (Join-Path $planRoot "package.json"),
    '{"name":"example","version":"1.0.0"}',
    [Text.UTF8Encoding]::new($false)
  )
  $config = @'
{
  "schemaVersion": 1,
  "projectName": "Example",
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
    "commands": [{"name":"Check {projectName}","command":"echo {version}"}],
    "artifacts": []
  },
  "publish": {
    "release": {"mode":"none"}
  }
}
'@
  [IO.File]::WriteAllText(
    (Join-Path $planRoot ".codex-release.json"),
    $config,
    [Text.UTF8Encoding]::new($false)
  )
  & git -C $planRoot config user.name "Project Release Test"
  & git -C $planRoot config user.email "auto-release@example.invalid"
  & git -C $planRoot add package.json .codex-release.json
  & git -C $planRoot commit -m "Initial test project" | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "initial commit failed" }
  & git -C $planRoot push --set-upstream origin main | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "initial push failed" }

  $standaloneStyle = (& $commitStyleScript -RepositoryRoot $planRoot) | ConvertFrom-Json
  Assert-Equal $standaloneStyle.selectedStyle "conventional" "Standalone analyzer did not require Conventional Commits"
  Assert-Equal $standaloneStyle.reason "required" "Standalone analyzer reported the wrong format reason"
  Assert-Equal $standaloneStyle.commitLanguage.selectedLanguage "Chinese" "Standalone analyzer did not preserve the compatible default language"
  $englishStandalone = (& $commitStyleScript -RepositoryRoot $planRoot -PromptLanguage English -Summary "chore: update release fixture") | ConvertFrom-Json
  Assert-Equal $englishStandalone.commitLanguage.selectedLanguage "English" "Standalone analyzer did not accept an English prompt language"
  Assert-Throws {
    & $commitStyleScript -RepositoryRoot $planRoot -Summary "Plain summary"
  } "must follow Conventional Commits" "Standalone analyzer accepted a non-Conventional summary"

  $plan = & $script `
    -Mode Plan `
    -Version v1.1.0 `
    -PromptLanguage English `
    -Summary "chore(release): release fixture" `
    -RepositoryRoot $planRoot
  $planText = $plan -join [Environment]::NewLine
  Assert-Match $planText "Project: Example" "plan missing configured project name"
  Assert-Match $planText "Target version: 1\.1\.0" "plan missing target version"
  Assert-Match $planText "Prepare command: Check Example -> echo 1\.1\.0" "plan did not expand configured command tokens"
  Assert-Match $planText "Release mode: none" "plan missing release strategy"

  & $script `
    -Mode Prepare `
    -Version v1.1.0 `
    -PromptLanguage English `
    -Summary "chore(release): release fixture" `
    -RepositoryRoot $planRoot
  $preparedPackage = Get-Content -Raw -Encoding UTF8 (Join-Path $planRoot "package.json") | ConvertFrom-Json
  Assert-Equal $preparedPackage.version "1.1.0" "Prepare did not apply the configured version update"

  $schema2Config = Get-Content -Raw -Encoding UTF8 (Join-Path $planRoot ".codex-release.json") | ConvertFrom-Json
  $schema2Config.schemaVersion = 2
  Write-TestUtf8 `
    (Join-Path $planRoot ".codex-release.json") `
    (($schema2Config | ConvertTo-Json -Depth 20) + "`n")
  $schema2Plan = & $script `
    -Mode Plan `
    -Version v1.1.0 `
    -PromptLanguage English `
    -Summary "chore(release): release fixture" `
    -RepositoryRoot $planRoot
  Assert-Match ($schema2Plan -join [Environment]::NewLine) "Project: Example" "release runner rejected schema v2"
}
finally {
  Remove-TestDirectory $planRoot
  Remove-TestDirectory $bareRoot
}
