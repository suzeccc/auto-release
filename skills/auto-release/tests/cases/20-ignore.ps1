# Auto Release contract case: 20-ignore.ps1
$ignoreRoot = New-TestDirectory "ignore"
try {
  & git -C $ignoreRoot config user.name "Ignore Audit Test"
  & git -C $ignoreRoot config user.email "ignore-audit@example.invalid"
  Write-TestUtf8 (Join-Path $ignoreRoot "package.json") '{"name":"ignore-fixture","version":"1.0.0"}'
  Write-TestUtf8 (Join-Path $ignoreRoot "package-lock.json") '{"name":"ignore-fixture","version":"1.0.0","lockfileVersion":3,"packages":{}}'
  Write-TestUtf8 (Join-Path $ignoreRoot ".env.example") "API_URL=https://example.invalid`n"
  Write-TestUtf8 (Join-Path $ignoreRoot ".gitignore") "node_modules/`n/output/`n"
  Write-TestUtf8 (Join-Path $ignoreRoot ".codex-release.json") "{}`n"
  Write-TestUtf8 (Join-Path $ignoreRoot "previews\preview.html") "preview`n"
  Write-TestUtf8 (Join-Path $ignoreRoot "nested\output\kept.bin") "nested output`n"
  & git -C $ignoreRoot add package.json package-lock.json .env.example .gitignore .codex-release.json previews/preview.html nested/output/kept.bin
  & git -C $ignoreRoot commit -m "Initial ignore fixture" | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "ignore fixture commit failed" }
  Write-TestUtf8 (Join-Path $ignoreRoot ".planning\notes.txt") "local planning`n"
  Write-TestUtf8 (Join-Path $ignoreRoot "dist\app.js") "generated`n"

  $ignoreAuditOutput = & $shell -NoProfile -ExecutionPolicy Bypass -File $invokeScript `
    -Operation Ignore -IgnoreMode Audit -RepositoryRoot $ignoreRoot -OutputFormat Json
  if ($LASTEXITCODE -ne 0) { throw "Ignore Audit process failed" }
  $ignoreAudit = ($ignoreAuditOutput | Select-Object -Last 1) | ConvertFrom-Json
  Assert-Equal $ignoreAudit.status "planned" "Ignore Audit returned the wrong status"
  Assert-Match (@($ignoreAudit.plan.detectedProjectTypes) -join ',') 'node' "Ignore Audit did not detect Node.js"
  Assert-Match (@($ignoreAudit.plan.rules.pattern) -join ',') '/previews/' "Ignore Audit did not recommend the local preview directory"
  Assert-Match (@($ignoreAudit.plan.rules.pattern) -join ',') 'dist/' "Ignore Audit did not recommend Node.js build output"
  Assert-Match (@($ignoreAudit.plan.rules.pattern) -join ',') 'output/' "Ignore Audit treated a root-only rule as coverage for a nested output path"
  Assert-Match (@($ignoreAudit.plan.rules.pattern) -join ',') '/\.planning/' "Ignore Audit did not recommend local planning state"
  Assert-Match (@($ignoreAudit.plan.rules.pattern) -join ',') '/\.codex-release\.json' "Ignore Audit did not recommend the local Auto Release config"
  Assert-Match (@($ignoreAudit.plan.untrackPaths) -join ',') 'previews/preview\.html' "Ignore Audit did not report a tracked generated file"
  Assert-Match (@($ignoreAudit.plan.untrackPaths) -join ',') '\.codex-release\.json' "Ignore Audit did not report the tracked local config"
  Assert-Match (@($ignoreAudit.plan.untrackPaths) -join ',') 'nested/output/kept\.bin' "Ignore Audit did not report the nested tracked output"
  Assert-Match (@($ignoreAudit.plan.protectedPaths) -join ',') 'package-lock\.json' "Ignore Audit did not protect the lock file"
  if ((@($ignoreAudit.plan.protectedPaths) -join ',') -match '\.codex-release\.json') { throw "Ignore Audit still protects the local config" }
  Assert-Equal @($ignoreAudit.plan.sensitivePaths).Count 0 "Ignore Audit treated .env.example as a secret"
  $previewHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $ignoreRoot "previews\preview.html")).Hash
  $localConfigHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $ignoreRoot ".codex-release.json")).Hash

  $ignoreApplyOutput = & $shell -NoProfile -ExecutionPolicy Bypass -File $invokeScript `
    -Operation Ignore -IgnoreMode ApplyAndUntrack -RepositoryRoot $ignoreRoot -OutputFormat Json
  if ($LASTEXITCODE -ne 0) { throw "Ignore ApplyAndUntrack process failed" }
  $ignoreApply = ($ignoreApplyOutput | Select-Object -Last 1) | ConvertFrom-Json
  Assert-Equal $ignoreApply.status "succeeded" "Ignore ApplyAndUntrack returned the wrong status"
  Assert-Match (Get-Content -Raw -Encoding UTF8 (Join-Path $ignoreRoot ".gitignore")) 'BEGIN Auto Release managed ignores' "Ignore Apply did not add the managed block"
  if (-not (Test-Path -LiteralPath (Join-Path $ignoreRoot "previews\preview.html") -PathType Leaf)) { throw "Ignore untracking removed the local preview" }
  Assert-Equal (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $ignoreRoot "previews\preview.html")).Hash $previewHash "Ignore untracking changed the local preview"
  if (-not (Test-Path -LiteralPath (Join-Path $ignoreRoot ".codex-release.json") -PathType Leaf)) { throw "Ignore untracking removed the local config" }
  Assert-Equal (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $ignoreRoot ".codex-release.json")).Hash $localConfigHash "Ignore untracking changed the local config"
  Assert-Match (git -C $ignoreRoot diff --cached --name-only) 'previews/preview\.html' "Ignore did not stage the tracked preview removal"
  Assert-Match (git -C $ignoreRoot diff --cached --name-only) '\.codex-release\.json' "Ignore did not stage the tracked config removal"
  & git -C $ignoreRoot check-ignore -q --no-index -- .codex-release.json
  if ($LASTEXITCODE -ne 0) { throw "Ignore Apply did not ignore the local config" }
  & git -C $ignoreRoot check-ignore -q --no-index -- dist/app.js
  if ($LASTEXITCODE -ne 0) { throw "Ignore Apply did not ignore dist output" }
  & git -C $ignoreRoot check-ignore -q --no-index -- nested/output/kept.bin
  if ($LASTEXITCODE -ne 0) { throw "Ignore Apply did not ignore the exact nested path before untracking" }
  $envExampleRule = git -C $ignoreRoot check-ignore -v --no-index -- .env.example
  Assert-Match ($envExampleRule -join [Environment]::NewLine) ':!\.env\.example\s' "Ignore Apply did not protect .env.example with a negative rule"
  & git -C $ignoreRoot check-ignore -q --no-index -- package-lock.json
  if ($LASTEXITCODE -eq 0) { throw "Ignore Apply hid package-lock.json" }

  $secondAuditOutput = & $shell -NoProfile -ExecutionPolicy Bypass -File $invokeScript `
    -Operation Ignore -IgnoreMode Audit -RepositoryRoot $ignoreRoot -OutputFormat Json
  if ($LASTEXITCODE -ne 0) { throw "second Ignore Audit process failed" }
  $ignoreTextBefore = Get-Content -Raw -Encoding UTF8 (Join-Path $ignoreRoot ".gitignore")
  $secondApplyOutput = & $shell -NoProfile -ExecutionPolicy Bypass -File $invokeScript `
    -Operation Ignore -IgnoreMode Apply -RepositoryRoot $ignoreRoot -OutputFormat Json
  if ($LASTEXITCODE -ne 0) { throw "idempotent Ignore Apply process failed" }
  $ignoreTextAfter = Get-Content -Raw -Encoding UTF8 (Join-Path $ignoreRoot ".gitignore")
  Assert-Equal $ignoreTextAfter $ignoreTextBefore "Ignore Apply was not idempotent"

  & $ignoreScript -Mode Audit -RepositoryRoot $ignoreRoot -OutputFormat Json | Out-Null
  $tamperedPlanPath = Join-Path $ignoreRoot ".git\auto-release\ignore-plan.json"
  $tamperedPlan = Get-Content -Raw -Encoding UTF8 $tamperedPlanPath | ConvertFrom-Json
  $tamperedPlan.untrackPaths = @($tamperedPlan.untrackPaths) + @("package.json")
  Write-TestUtf8 $tamperedPlanPath (($tamperedPlan | ConvertTo-Json -Depth 20) + "`n")
  Assert-Throws {
    & $ignoreScript -Mode ApplyAndUntrack -RepositoryRoot $ignoreRoot
  } "not ignored by the applied rules" "Ignore ApplyAndUntrack accepted an exact path that remained visible"
  Assert-Match (git -C $ignoreRoot ls-files -- package.json) '^package\.json$' "Failed exact-path validation changed the index"

  & $ignoreScript -Mode Audit -RepositoryRoot $ignoreRoot -OutputFormat Json | Out-Null
  Write-TestUtf8 (Join-Path $ignoreRoot "changed-after-audit.txt") "changed`n"
  Assert-Throws {
    & $ignoreScript -Mode Apply -RepositoryRoot $ignoreRoot
  } "fingerprint is stale" "Ignore Apply accepted a stale plan"
}
finally {
  Remove-TestDirectory $ignoreRoot
}
$ignoreRegressionRoot = New-TestDirectory "ignore-regression"
try {
  & git -C $ignoreRegressionRoot config user.name "Ignore Regression Test"
  & git -C $ignoreRegressionRoot config user.email "ignore-regression@example.invalid"
  $unicodeDirectory = -join @([char]0x6587, [char]0x6863)
  $unicodeFileName = (-join @([char]0x5FEB, [char]0x901F, [char]0x4E86, [char]0x89E3)) + ".md"
  $unicodeIgnorePath = "$unicodeDirectory/.gitignore"
  $unicodeDocumentPath = "$unicodeDirectory/$unicodeFileName"
  $edgeSpacePath = " leading.txt"
  Write-TestUtf8 (Join-Path $ignoreRegressionRoot ".gitignore") "reports/`n.superpowers/`ndeliverables/`ndocs/superpowers/`n.env`n\ leading.txt`n"
  Write-TestUtf8 (Join-Path $ignoreRegressionRoot ".codegraph\.gitignore") "*`n!.gitignore`n"
  Write-TestUtf8 (Join-Path $ignoreRegressionRoot ".superpowers\brainstorm\.last-token") "local-agent-token`n"
  Write-TestUtf8 (Join-Path $ignoreRegressionRoot ".claude\settings.local.json") "{}"
  Write-TestUtf8 (Join-Path $ignoreRegressionRoot ".cursor\rules\project.mdc") "Project rule`n"
  Write-TestUtf8 (Join-Path $ignoreRegressionRoot ".agents\skills\sample\SKILL.md") "# Shared skill`n"
  Write-TestUtf8 (Join-Path $ignoreRegressionRoot ".codex\sessions\session.json") "{}"
  Write-TestUtf8 (Join-Path $ignoreRegressionRoot ".hbuilderx\state.json") "{}"
  Write-TestUtf8 (Join-Path $ignoreRegressionRoot ".aider.chat.history.md") "# Local chat`n"
  Write-TestUtf8 (Join-Path $ignoreRegressionRoot "playwright-report\index.html") "report`n"
  Write-TestUtf8 (Join-Path $ignoreRegressionRoot "reports\result.json") "{}"
  Write-TestUtf8 (Join-Path $ignoreRegressionRoot $edgeSpacePath) "edge-space path`n"
  Write-TestUtf8 (Join-Path $ignoreRegressionRoot "deliverables\final.pptx") "fixture`n"
  Write-TestUtf8 (Join-Path $ignoreRegressionRoot "artifacts\build.zip") "fixture`n"
  Write-TestUtf8 (Join-Path $ignoreRegressionRoot "generated\client.ts") "generated`n"
  Write-TestUtf8 (Join-Path $ignoreRegressionRoot "screenshots\home.png") "fixture`n"
  Write-TestUtf8 (Join-Path $ignoreRegressionRoot "snapshots\home.snap") "fixture`n"
  Write-TestUtf8 (Join-Path $ignoreRegressionRoot "docs\superpowers\plan.md") "# Local plan`n"
  Write-TestUtf8 (Join-Path $ignoreRegressionRoot $unicodeIgnorePath) "*.tmp`n"
  Write-TestUtf8 (Join-Path $ignoreRegressionRoot $unicodeDocumentPath) "# Unicode path fixture`n"
  & git -C $ignoreRegressionRoot add -f -- .gitignore .codegraph/.gitignore .superpowers/brainstorm/.last-token .claude/settings.local.json .cursor/rules/project.mdc .agents/skills/sample/SKILL.md .codex/sessions/session.json .hbuilderx/state.json .aider.chat.history.md playwright-report/index.html reports/result.json $edgeSpacePath deliverables/final.pptx artifacts/build.zip generated/client.ts screenshots/home.png snapshots/home.snap docs/superpowers/plan.md $unicodeIgnorePath $unicodeDocumentPath
  & git -C $ignoreRegressionRoot commit -m "Initial ignore regression fixture" | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "ignore regression fixture commit failed" }
  Write-TestUtf8 (Join-Path $ignoreRegressionRoot ".env") "IGNORED_SECRET=fixture`n"

  $ignoreRegressionOutput = & $shell -NoProfile -ExecutionPolicy Bypass -File $invokeScript `
    -Operation Ignore -IgnoreMode Audit -RepositoryRoot $ignoreRegressionRoot -OutputFormat Json
  if ($LASTEXITCODE -ne 0) { throw "Ignore regression Audit process failed" }
  $ignoreRegression = ($ignoreRegressionOutput | Select-Object -Last 1) | ConvertFrom-Json
  Assert-Equal $ignoreRegression.status "planned" "Ignore regression Audit returned the wrong status"
  Assert-Match (@($ignoreRegression.plan.ignoreFiles) -join ',') ([regex]::Escape($unicodeIgnorePath)) "Ignore Audit did not preserve a Unicode Git path"
  $safeIgnorePatterns = @($ignoreRegression.plan.rules.pattern) + @($ignoreRegression.plan.alreadyCovered.pattern)
  Assert-Match ($safeIgnorePatterns -join ',') '/\.codegraph/' "Ignore Audit did not classify local CodeGraph state"
  Assert-Match (@($ignoreRegression.plan.alreadyCovered.pattern) -join ',') '/\.superpowers/' "Ignore Audit did not recognize the existing agent-state rule"
  Assert-Match ($safeIgnorePatterns -join ',') '/\.claude/settings\.local\.json' "Ignore Audit did not classify Claude local settings"
  Assert-Match ($safeIgnorePatterns -join ',') '/\.codex/sessions/' "Ignore Audit did not classify Codex local sessions"
  Assert-Match ($safeIgnorePatterns -join ',') '/\.aider\.chat\.history\.md' "Ignore Audit did not classify Aider chat history"
  Assert-Match ($safeIgnorePatterns -join ',') '/\.hbuilderx/' "Ignore Audit did not classify HBuilderX local state"
  Assert-Match ($safeIgnorePatterns -join ',') '/playwright-report/' "Ignore Audit did not classify Playwright reports"
  Assert-Match (@($ignoreRegression.plan.review.pattern) -join ',') '/reports/' "Ignore Audit did not flag reports for review"
  Assert-Match (@($ignoreRegression.plan.review.pattern) -join ',') '/deliverables/' "Ignore Audit did not flag deliverables for review"
  Assert-Match (@($ignoreRegression.plan.review.pattern) -join ',') '/\.cursor/' "Ignore Audit did not flag Cursor project rules for review"
  Assert-Match (@($ignoreRegression.plan.review.pattern) -join ',') '/\.agents/' "Ignore Audit did not flag shared agent skills for review"
  Assert-Match (@($ignoreRegression.plan.review.pattern) -join ',') '/artifacts/' "Ignore Audit did not flag ambiguous artifacts for review"
  Assert-Match (@($ignoreRegression.plan.review.pattern) -join ',') '/generated/' "Ignore Audit did not flag generated sources for review"
  Assert-Match (@($ignoreRegression.plan.review.pattern) -join ',') '/screenshots/' "Ignore Audit did not flag screenshots for review"
  Assert-Match (@($ignoreRegression.plan.review.pattern) -join ',') '/snapshots/' "Ignore Audit did not flag snapshots for review"
  Assert-Match (@($ignoreRegression.plan.untrackPaths) -join ',') '\.codegraph/\.gitignore' "Ignore Audit did not identify tracked CodeGraph state"
  Assert-Match (@($ignoreRegression.plan.untrackPaths) -join ',') '\.superpowers/brainstorm/\.last-token' "Ignore Audit did not identify tracked agent state"
  Assert-Match (@($ignoreRegression.plan.untrackPaths) -join ',') '\.claude/settings\.local\.json' "Ignore Audit did not identify tracked Claude local settings"
  Assert-Match (@($ignoreRegression.plan.untrackPaths) -join ',') '\.hbuilderx/state\.json' "Ignore Audit did not identify tracked HBuilderX state"
  $trackedButIgnoredPaths = @($ignoreRegression.plan.trackedButIgnored.path) -join ','
  Assert-Match $trackedButIgnoredPaths '\.superpowers/brainstorm/\.last-token' "Ignore Audit missed tracked agent state already covered by .gitignore"
  Assert-Match $trackedButIgnoredPaths 'reports/result\.json' "Ignore Audit missed a tracked report already covered by .gitignore"
  if (-not (@($ignoreRegression.plan.trackedButIgnored.path) -ccontains $edgeSpacePath)) { throw "Ignore Audit did not preserve a leading-space tracked path" }
  Assert-Match $trackedButIgnoredPaths 'deliverables/final\.pptx' "Ignore Audit missed a tracked deliverable already covered by .gitignore"
  Assert-Match $trackedButIgnoredPaths 'docs/superpowers/plan\.md' "Ignore Audit missed an unknown tracked path already covered by .gitignore"
  Assert-Match (@($ignoreRegression.plan.sensitivePaths) -join ',') '\.superpowers/brainstorm/\.last-token' "Ignore Audit did not classify the local agent token as sensitive"
  Assert-Match (@($ignoreRegression.plan.sensitivePaths) -join ',') '(?:^|,)\.env(?:,|$)' "Ignore Audit omitted an already-ignored untracked .env file"
  $ignoreHumanOutput = (& $ignoreScript -Mode Audit -RepositoryRoot $ignoreRegressionRoot -NoWritePlan -OutputFormat Human 6>&1 | Out-String)
  Assert-Match $ignoreHumanOutput 'Tracked but ignored: reports/result\.json' "Human Ignore output omitted tracked-but-ignored files"
}
finally {
  Remove-TestDirectory $ignoreRegressionRoot
}

$ignoreSkillRoot = New-TestDirectory "ignore-skill"
try {
  & git -C $ignoreSkillRoot config user.name "Ignore Skill Test"
  & git -C $ignoreSkillRoot config user.email "ignore-skill@example.invalid"
  Write-TestUtf8 (Join-Path $ignoreSkillRoot ".gitignore") ""
  Write-TestUtf8 (Join-Path $ignoreSkillRoot "skills\sample-skill\SKILL.md") @'
---
name: sample-skill
description: A fixture Codex Skill used to validate repository-aware ignore behavior.
---

# Sample Skill
'@
  Write-TestUtf8 (Join-Path $ignoreSkillRoot "skills\sample-skill\agents\openai.yaml") "interface:`n  display_name: `"Sample Skill`"`n"
  Write-TestUtf8 (Join-Path $ignoreSkillRoot "skills\sample-skill\scripts\run.ps1") "Write-Output `"fixture`"`n"
  Write-TestUtf8 (Join-Path $ignoreSkillRoot "skills\sample-skill\references\guide.md") "# Guide`n"
  Write-TestUtf8 (Join-Path $ignoreSkillRoot "skills\sample-skill\assets\template.txt") "template`n"
  Write-TestUtf8 (Join-Path $ignoreSkillRoot "docs\SKILL.md") "# Documentation named SKILL.md without frontmatter`n"
  & git -C $ignoreSkillRoot add -- .gitignore skills/sample-skill docs/SKILL.md
  & git -C $ignoreSkillRoot commit -m "Initial Skill fixture" | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "ignore Skill fixture commit failed" }
  Write-TestUtf8 (Join-Path $ignoreSkillRoot ".install-test\sample-skill\SKILL.md") "local install copy`n"

  $ignoreSkillOutput = & $shell -NoProfile -ExecutionPolicy Bypass -File $invokeScript `
    -Operation Ignore -IgnoreMode Audit -RepositoryRoot $ignoreSkillRoot -OutputFormat Json
  if ($LASTEXITCODE -ne 0) { throw "Ignore Skill Audit process failed" }
  $ignoreSkill = ($ignoreSkillOutput | Select-Object -Last 1) | ConvertFrom-Json
  Assert-Match (@($ignoreSkill.plan.detectedProjectTypes) -join ',') 'codex-skill' "Ignore Audit did not detect a Codex Skill repository"
  Assert-Equal @($ignoreSkill.plan.detectedSkillRoots).Count 1 "Ignore Audit returned the wrong number of Skill roots"
  Assert-Equal ([string]@($ignoreSkill.plan.detectedSkillRoots)[0]) "skills/sample-skill" "Ignore Audit returned the wrong Skill root"
  Assert-Match (@($ignoreSkill.plan.rules.pattern) -join ',') '/\.install-test/' "Ignore Audit did not recommend the Skill install-test sandbox"
  $installTestRule = @($ignoreSkill.plan.rules | Where-Object { $_.pattern -eq "/.install-test/" }) | Select-Object -First 1
  Assert-Match (@($installTestRule.untrackedMatches) -join ',') '\.install-test/sample-skill/SKILL\.md' "Ignore Audit did not match local Skill installation state"
  foreach ($protectedSkillPath in @(
    "skills/sample-skill/SKILL.md",
    "skills/sample-skill/agents/openai.yaml",
    "skills/sample-skill/scripts/run.ps1",
    "skills/sample-skill/references/guide.md",
    "skills/sample-skill/assets/template.txt"
  )) {
    Assert-Match (@($ignoreSkill.plan.protectedPaths) -join ',') ([regex]::Escape($protectedSkillPath)) "Ignore Audit did not protect Skill source: $protectedSkillPath"
  }
  Assert-Equal @($ignoreSkill.plan.untrackPaths | Where-Object { $_ -like "skills/sample-skill/*" }).Count 0 "Ignore Audit proposed untracking Skill source"

  $ignoreSkillApplyOutput = & $shell -NoProfile -ExecutionPolicy Bypass -File $invokeScript `
    -Operation Ignore -IgnoreMode Apply -RepositoryRoot $ignoreSkillRoot -OutputFormat Json
  if ($LASTEXITCODE -ne 0) { throw "Ignore Skill Apply process failed" }
  & git -C $ignoreSkillRoot check-ignore -q --no-index -- .install-test/sample-skill/SKILL.md
  if ($LASTEXITCODE -ne 0) { throw "Ignore Apply did not ignore the Skill install-test sandbox" }
  & git -C $ignoreSkillRoot check-ignore -q --no-index -- skills/sample-skill/SKILL.md
  if ($LASTEXITCODE -eq 0) { throw "Ignore Apply hid the Skill manifest" }
}
finally {
  Remove-TestDirectory $ignoreSkillRoot
}

$ignoreMarkerRoot = New-TestDirectory "ignore-markers"
try {
  & git -C $ignoreMarkerRoot config user.name "Ignore Marker Test"
  & git -C $ignoreMarkerRoot config user.email "ignore-marker@example.invalid"
  Write-TestUtf8 (Join-Path $ignoreMarkerRoot ".gitignore") "# END Auto Release managed ignores`n# BEGIN Auto Release managed ignores`n"
  Write-TestUtf8 (Join-Path $ignoreMarkerRoot "README.md") "# Fixture`n"
  & git -C $ignoreMarkerRoot add .gitignore README.md
  & git -C $ignoreMarkerRoot commit -m "Initial malformed marker fixture" | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "ignore marker fixture commit failed" }
  & $ignoreScript -Mode Audit -RepositoryRoot $ignoreMarkerRoot -OutputFormat Json | Out-Null
  Assert-Throws {
    & $ignoreScript -Mode Apply -RepositoryRoot $ignoreMarkerRoot
  } "END appears before BEGIN" "Ignore Apply accepted reversed managed markers"
}
finally {
  Remove-TestDirectory $ignoreMarkerRoot
}
