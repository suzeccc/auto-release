# Auto Release contract case: 60-static-contract.ps1
Assert-Match $scriptSource '\.codex-release\.json' "script does not use repository config"
Assert-Match $scriptSource 'remoteUrlPattern' "script does not validate configured remote"
Assert-Match $scriptSource 'git.*push|"push"' "script does not push releases"
Assert-Match $scriptSource '"--atomic"' "script does not use atomic push"
Assert-Match $scriptSource 'Local tag .* points to .* current HEAD' "missing local tag conflict guard"
Assert-Match $scriptSource 'Remote tag .* points to .* current HEAD' "missing remote tag conflict guard"
Assert-Match $scriptSource 'ahead or diverged' "missing remote divergence guard"
Assert-Match $scriptSource 'already public and verified' "missing idempotent public release verification"
Assert-Match $scriptSource 'Invoke-GitHubChecked' "GitHub commands are not repository-bound"
Assert-Match $scriptSource 'Downloaded release asset SHA256 mismatch' "release assets are not downloaded and hash-verified"
Assert-Match $scriptSource '"--draft", "--verify-tag"' "create mode is not draft-first"
Assert-Match $scriptSource 'gh\.exe' "missing GitHub CLI fallback"
Assert-Match $scriptSource 'Invoke-ParallelShellChecked' "missing parallel prepare support"
Assert-Match $scriptSource 'Expand-ConfigTokens \(\[string\]\$_.command\)' "prepare commands do not expand release tokens"
Assert-Match $scriptSource 'publish-draft.*create.*none' "missing release modes"
Assert-Match $scriptSource 'schemaVersion -notin @\(1, 2\)' "release runner does not accept schema v1 and v2"
Assert-Match $scriptSource 'LocalBuild' "release runner does not support local builds"
Assert-Match $scriptSource '\$script:normalizedVersion = Get-CurrentVersion' "LocalBuild does not retain the detected project version for artifact validation"
Assert-Match $scriptSource 'Stop-ProcessesUsingLocalArtifacts' "LocalBuild does not stop processes using local artifacts"
Assert-Match $scriptSource 'SkipBuild' "release runner cannot reuse a current local build"
Assert-Match $scriptSource 'AllowExistingHead' "release runner cannot publish without an unnecessary empty commit"
if ($scriptSource -match 'D:\\QiLin|CopyShare|suzeccc') {
  throw "generic release script still contains CopyShare-specific values"
}
if ($scriptSource -match 'gh.*run.*watch') {
  throw "script must use structured workflow polling"
}

Assert-Match $skill '^---[\s\S]*name: auto-release' "skill name is not auto-release"
Assert-Match $skill '\.codex-release\.json' "skill does not document repository config"
Assert-Match $releaseReferenceSource 'Plan[\s\S]*Prepare[\s\S]*Publish' "release reference is missing phase order"
Assert-Match $skill '`--force`' "missing force-push guard"
Assert-Match $skill '`git add \.`' "missing staging guard"
Assert-Match $skill 'Detect[\s\S]*Generate[\s\S]*Validate' "skill does not document project setup modes"
Assert-Match $skill 'LocalBuild[\s\S]*CommitPush[\s\S]*Release' "skill does not document the three user operations"
Assert-Match $skill 'LocalBuild[\s\S]*Ignore[\s\S]*CommitPush[\s\S]*Release' "skill does not document all four user operations"
Assert-Match $skill 'PromptLanguage Chinese[\s\S]*PromptLanguage English[\s\S]*Auto' "skill does not route commit language from the user prompt"
Assert-Match $referenceSource 'publish-draft' "config reference missing draft strategy"
Assert-Match $referenceSource 'uploadAssets' "config reference missing upload assets"
Assert-Match $referenceSource 'PromptLanguage.*Chinese.*English.*Auto' "config reference missing prompt-language modes"

$setupSource = (Get-Content -Raw -Encoding UTF8 $setupScript) + "`n" + (Get-Content -Raw -Encoding UTF8 $setupProfilesScript) + "`n" + (Get-Content -Raw -Encoding UTF8 $setupGenerationScript)
Assert-Match $setupSource 'Refusing to overwrite human-managed workflow' "setup script lacks workflow overwrite protection"
Assert-Match $setupSource 'Auto Release local configuration' "setup script does not add the local config ignore rule"
Assert-Match $setupSource 'commit\.fallback must be conventional' "setup script does not validate the commit fallback"
Assert-Match $setupSource 'CreateSeparate[\s\S]*ReuseCompatible' "setup script lacks human workflow policies"
Assert-Match $setupSource 'tauri[\s\S]*node[\s\S]*go' "setup script does not support all project types"
foreach ($projectType in @("python", "rust", "dotnet", "java")) {
  Assert-Match $setupSource ('"' + $projectType + '"') "setup script does not support $projectType"
}
foreach ($projectType in @("cmake", "flutter", "android", "electron", "docker")) {
  Assert-Match $setupSource ('"' + $projectType + '"') "setup script does not support $projectType"
}
if ($setupSource -match 'D:\\QiLin|CopyShare|suzeccc') {
  throw "generic setup script contains project-specific values"
}
$invokeSource = (Get-Content -Raw -Encoding UTF8 $invokeScript) + "`n" + (Get-Content -Raw -Encoding UTF8 $invokeCommitScript) + "`n" + (Get-Content -Raw -Encoding UTF8 $invokeBuildScript)
Assert-Match $invokeSource 'ValidateSet\("LocalBuild", "Ignore", "CommitPush", "Release"\)' "unified operation entrypoint is incomplete"
Assert-Match $invokeSource 'git.*"add", "-A"|@\("add", "-A"\)' "CommitPush does not stage all changes"
Assert-Match $invokeSource 'possible secret file' "CommitPush lacks secret path protection"
Assert-Match $invokeSource 'sourceFingerprint' "Release lacks local build freshness tracking"
Assert-Match $invokeSource 'AllowExistingHead' "Release does not support unchanged working trees"
Assert-Match $invokeSource 'RequestedOperation -eq "LocalBuild"' "LocalBuild does not bypass GitHub workflow validation"
Assert-Match $invokeSource 'Mode GenerateLocal' "First-time LocalBuild still creates a GitHub release workflow"
Assert-Match $invokeSource 'Assert-CommitSummaryStyle' "CommitPush does not enforce the analyzed commit style"
Assert-Match $invokeSource 'ValidateSet\("Auto", "Chinese", "English"\)' "unified entrypoint does not expose prompt language"
Assert-Match $invokeSource 'Assert-CommitSummaryLanguage' "CommitPush does not enforce prompt-language summaries"
Assert-Match $invokeSource 'CommitStrategy.*AutoSplit' "CommitPush does not expose automatic multi-commit execution"
Assert-Match $invokeSource 'auto-release/transaction-' "CommitPush does not use a transaction branch"
Assert-Match $invokeSource 'Commit plan does not cover all changes' "CommitPush does not require exact plan coverage"
Assert-Match $invokeSource 'ValidateSet\("Audit", "Apply", "ApplyAndUntrack"\)' "unified operation entrypoint does not expose Ignore modes"
Assert-Match $invokeSource 'Local release config is still tracked' "CommitPush does not reject a tracked local config"
$utilsSource = Get-Content -Raw -Encoding UTF8 $utils
Assert-Match $utilsSource 'Get-RepositoryCommitLanguageAnalysis' "commit language does not support repository-history fallback"
Assert-Match $utilsSource 'Get-CommitDescription' "commit language incorrectly includes style prefixes"
$ignoreSource = (Get-Content -Raw -Encoding UTF8 $ignoreScript) + "`n" + (Get-Content -Raw -Encoding UTF8 $ignoreGitScript) + "`n" + (Get-Content -Raw -Encoding UTF8 $ignoreCandidatesScript)
Assert-Match $ignoreSource 'BEGIN Auto Release managed ignores' "Ignore operation lacks a managed block"
Assert-Match $ignoreSource 'worktree fingerprint is stale' "Ignore operation does not reject stale plans"
Assert-Match $ignoreSource 'rm.*--cached' "Ignore operation cannot stop tracking generated files"
Assert-Match $ignoreSource 'Restore-Index' "Ignore operation cannot restore the original index"
Assert-Match $ignoreSource 'Regenerable machine-local Auto Release configuration' "Ignore operation does not classify the local config"
Assert-Match $referenceSource 'Conventional Commits' "config reference does not document commit-style fallback"
foreach ($template in $workflowTemplates) {
  $templateSource = Get-Content -Raw -Encoding UTF8 $template
  Assert-Match $templateSource '^# Generated by Auto Release' "workflow template lacks managed marker"
  Assert-Match $templateSource 'permissions:[\s\S]*contents: write' "workflow template lacks release permissions"
  Assert-Match $templateSource 'draft|releaseDraft' "workflow template does not create a draft release"
  Assert-Match $templateSource '(?m)^concurrency:\s*$' "workflow template lacks concurrency control"
  Assert-Match $templateSource '(?m)^\s+timeout-minutes:\s*\d+\s*$' "workflow template lacks a job timeout"
  if ($templateSource -match '(?m)^\s*(?:-\s*)?uses:\s*[^\s]+@(?:v\d+|stable)') {
    throw "workflow template contains a floating action reference: $template"
  }
  if ($templateSource -match 'actions/upload-artifact@') {
    Assert-Match $templateSource '(?m)^\s+retention-days:\s*\d+\s*$' "workflow template lacks artifact retention"
  }
}

Write-Host "auto-release contract passed"
