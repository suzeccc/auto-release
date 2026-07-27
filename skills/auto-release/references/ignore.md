# Ignore 审计与应用

`Ignore` 只处理当前 Git 仓库，不扫描仓库外的用户目录。默认 `Audit` 为只读工作区操作，仅把计划写入 `.git/auto-release/ignore-plan.json`；`-WhatIf` 连计划文件也不写。

## 模式

```powershell
$invoke = "$env:USERPROFILE\.codex\skills\auto-release\scripts\invoke-release.ps1"

& $invoke -Operation Ignore -IgnoreMode Audit -RepositoryRoot "<仓库根目录>"
& $invoke -Operation Ignore -IgnoreMode Apply -RepositoryRoot "<仓库根目录>"
& $invoke -Operation Ignore -IgnoreMode ApplyAndUntrack -RepositoryRoot "<仓库根目录>"
```

- `Audit`：识别项目类型、现有忽略来源、候选规则、已跟踪匹配、已被忽略但仍被跟踪的文件、敏感路径、受保护路径和历史生成路径；已忽略但未跟踪的 `.env`、私钥和令牌文件仍会进入敏感路径报告。
- `Apply`：只把高置信度缺失规则追加到根 `.gitignore` 的托管区块，不暂存、提交或推送。
- `ApplyAndUntrack`：在 `Apply` 基础上对计划中的精确已跟踪文件执行 `git rm --cached`；本地文件内容和 SHA256 必须保持不变。

## 计划

计划包含 `baseHead` 和完整工作区指纹。应用前 HEAD、暂存区、未暂存区或未跟踪文件发生任何变化时，计划作废，必须重新 `Audit`。

```json
{
  "schemaVersion": 1,
  "baseHead": "commit SHA",
  "worktreeFingerprint": "SHA256",
  "rules": [
    {
      "pattern": "/previews/",
      "reason": "Local design and preview artifacts",
      "confidence": 1,
      "trackedMatches": ["previews/example.html"]
    }
  ],
  "untrackPaths": ["previews/example.html"],
  "trackedButIgnored": [
    {
      "path": "reports/result.json",
      "pattern": "reports/",
      "source": ".gitignore",
      "line": 8
    }
  ],
  "sensitivePaths": [],
  "protectedPaths": ["package-lock.json"]
}
```

`trackedButIgnored` 是反向审计结果：`.gitignore` 只影响未跟踪文件，已进入 Git index 的文件即使命中规则也会继续上传。该列表报告命中的路径、规则及来源，但不会把未知目录自动加入 `untrackPaths`；需要人工确认后再停止跟踪。

## 分类规则

- 只自动应用置信度至少 0.8 的候选规则。
- 已跟踪文件默认进入 `review`；只有明确的构建、本地输出或无引用预览允许进入安全计划。
- `.codegraph/`、`.superpowers/`、`.planning/`、`.playwright-cli/` 作为明确的 Agent 本地状态审计。
- 根 `.codex-release.json` 固定作为高置信度、可再生的本机 Auto Release 配置；规则使用精确的 `/.codex-release.json`，已跟踪时允许安全停止跟踪。
- 根 `SKILL.md` 和 `skills/*/SKILL.md` 只有同时具备 `name`、`description` frontmatter 时才识别为 Codex Skill；计划在 `detectedSkillRoots` 报告根目录，并保护其中全部已跟踪源码。
- Codex Skill 仓库只新增根 `/.install-test/` 高置信度候选，用于本地安装验证沙箱；不得自动忽略 `SKILL.md`、`agents/`、`scripts/`、`references/`、`assets/`、整个 `.codex/` 或整个 `.agents/`。
- Claude、Cursor、Codex、Gemini、Aider、Serena、Windsurf、Cline、Roo、Continue、OpenCode 等工具只自动处理明确的缓存、会话、历史、临时 worktree 和 `settings.local.json`；整个工具目录可能包含共享规则、技能或项目配置，必须进入 `review`。
- HBuilderX 和编辑器本地历史可作为本地状态；`.vscode/`、`.fleet/`、`.zed/` 可能是团队配置，必须进入 `review`。
- Playwright、Allure、Coverage、NYC、JUnit 等明确生成的测试报告可进入安全计划；`reports/`、`deliverables/`、`artifacts/`、`generated/`、`screenshots/`、`snapshots/`、`tmp/`、`temp/` 可能包含正式成果、生成源码或测试基线，必须进入 `review`，不得擅自整体忽略。
- 实际 `.env`、私钥、签名凭据或 `.last-token` 等 Agent 令牌存在时停止应用，不能用忽略规则代替凭据处置。
- 锁文件和 `.github/workflows/**` 为受保护路径；新规则不得改变它们的可见性。`.codex-release.json` 由上述精确本机配置规则单独管理。
- `build/`、`dist/`、`target/`、`bin/`、`obj/` 等规则只有检测到对应工具链时才生成；发现已跟踪引用时转入 `review`。
- `.env.*` 必须与 `!.env.example` 一起管理。
- Git 文件清单使用 NUL 分隔并关闭 `core.quotepath` 转义，中文和其他 Unicode 路径必须以原文进入计划。

## 托管区块

人工内容、顺序和注释保持不变。托管规则只追加到以下区块；标记缺失时创建，标记不完整、重复或结束标记出现在开始标记之前时停止：

```gitignore
# BEGIN Auto Release managed ignores

# Build
output/

# END Auto Release managed ignores
```

重复执行必须幂等。后续新增规则追加到现有区块，禁止删除旧托管规则。

## 回滚和验证

应用前备份 `.gitignore` 和 Git index。失败时恢复二者。应用后验证：

- 每个新增规则通过 `git check-ignore --no-index` 命中探针。
- 每个候选规则的探针和全部精确匹配路径都必须被忽略；根目录规则不能冒充对同名嵌套目录的覆盖。
- 执行 `git rm --cached` 前，计划中的每一个精确路径都必须已被忽略，否则恢复 `.gitignore` 和 index。
- 原本可见的受保护路径仍然可见。
- `git diff --check` 通过。
- `ApplyAndUntrack` 前后的本地文件数量、路径和 SHA256 一致。

本操作不删除本地文件、不提交、不推送、不重写 Git 历史。完成后如需提交，另行执行 `CommitPush`；分类提交应把 `.gitignore` 与停止跟踪的文件放入同一个 `chore(repo)` 组。
