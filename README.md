# Auto Release

让 Codex 帮你完成**本地打包、提交推送和 GitHub 正式发布**。

你只需要说明想做什么，Auto Release 会识别项目类型、选择正确的构建方式，并在需要时创建 GitHub Actions 发布工作流。

## 它能做什么

| 你想做的事 | Auto Release 会做什么 | 不会做什么 |
|---|---|---|
| 本地测试打包 | 构建当前项目，把结果放到 `output/` | 不改版本、不提交、不推送 |
| 检查忽略规则 | 深度检查并补全 `.gitignore`，可停止跟踪本地产物 | 不删除本地文件、不重写历史 |
| 提交并推送 | 检查改动和敏感文件，生成提交信息，推送当前分支 | 不自动合并、不变基、不强推 |
| 正式发布 | 更新版本、测试、构建、提交、打标签、运行 GitHub Actions、发布 GitHub Release | 发布失败时不会公开不完整的 Release |

如果你的表达不够明确，Codex 会让你从 `LocalBuild`、`Ignore`、`CommitPush`、`Release` 四种操作中选择，不会把“本地打包”误认为正式发布。

## 支持哪些项目

Auto Release 当前支持 12 类常见项目：

| 类型 | 典型发布结果 |
|---|---|
| Tauri | Windows 安装包、macOS DMG、Linux 包 |
| Node.js | npm `.tgz` 包 |
| Go | Windows、Linux、macOS 的 amd64/arm64 程序 |
| Python | wheel 和 sdist |
| Rust | `.crate` 包 |
| .NET | `.nupkg` 包 |
| Java | Maven 或 Gradle 生成的 `.jar` |
| CMake | Windows、Linux、macOS 的多架构压缩包 |
| Flutter | 移动端、桌面端和 Web 构建 |
| Android | APK 和 AAB |
| Electron | Windows、Linux、macOS 的多架构压缩包 |
| Docker | 推送到 GHCR 的多架构镜像 |

实际生成多少个安装包或产物，取决于项目类型和它对应的平台矩阵。

## 安装

在 PowerShell 中运行：

```powershell
python -X utf8 "$env:USERPROFILE\.codex\skills\.system\skill-installer\scripts\install-skill-from-github.py" --repo suzeccc/auto-release --path skills/auto-release
```

安装完成后，重新打开一个 Codex 任务，让 Skill 列表刷新。

## 最快使用方式

进入任意本地 Git 项目，直接告诉 Codex：

### 只想在本地试一下

```text
本地打包这个项目，不要改版本，也不要提交
```

### 想提交当前改动

```text
检查这些修改，生成合适的提交信息，然后提交并推送
```

### 想检查不该上传的文件

```text
忽略
```

只输入“忽略”时，Auto Release 先执行只读审计并展示计划，不会直接修改 `.gitignore`。

### 想创建自动发布工作流

```text
给这个项目创建 GitHub Release 工作流
```

### 想正式发布新版本

```text
正式发布 v1.2.3
```

首次使用时，Auto Release 会先识别项目并生成项目专用配置。以后会复用这份配置，不会每次重新猜测。

## 三种操作

### 1. LocalBuild：本地测试打包

适合开发过程中快速验证程序是否能正常构建。

- 不修改项目版本。
- 不创建 Git 提交。
- 不推送代码或标签。
- 产物统一放到 `output/<项目名><扩展名>`。
- 文件名不包含版本号，方便反复覆盖和测试。
- 源码与产物未变化时，会复用上次有效结果。

需要忽略缓存重新构建时，告诉 Codex“强制重新打包”。

### 2. Ignore：检查并补全忽略规则

适合提交项目或公开 GitHub 仓库前检查本地文件、构建产物和缓存。

- 识别项目类型和对应工具链产物。
- 检查现有 `.gitignore`、Git 本地排除规则和当前文件状态。
- 区分安全补全、需要确认、敏感文件和必须保留文件。
- 默认只生成计划，不修改工作区。
- 可以只补全规则，也可以停止跟踪已经上传的生成文件。
- 停止跟踪时保留本地文件并验证 SHA256。
- 不删除文件、不提交、不推送、不重写历史。

`.gitignore` 对已经跟踪的文件无效；这类文件必须明确选择“补全并停止跟踪”。任何应用操作失败都会恢复 `.gitignore` 和原暂存区。

### 3. CommitPush：提交并推送

适合完成一轮修改后，把全部安全改动提交到当前分支。

- 同时处理已暂存、未暂存、删除和未跟踪文件。
- 遵守 `.gitignore`。
- 发现 `.env`、私钥、凭据或常见 Token 时停止。
- 自动分析最近提交风格。
- 风格无法确定时回退到 Conventional Commits。
- 能把不同目的的改动分类成 2 至 4 个独立提交，再一次性推送。
- 分类或任一提交失败时恢复原分支和原有改动，不推送半成品。
- 远程分支领先或发生分叉时停止，不擅自处理历史。

Auto Release 使用 Conventional Commits 时，类型和可选范围使用英文，说明使用中文，例如：

```text
feat: 新增自动发布工作流
fix(release): 修复标签发布失败
docs: 更新安装说明
```

例如同时修改 `.gitignore` 和前端性能代码时，可以自动形成：

```text
chore(repo): 停止跟踪本地预览与开发产物
perf(frontend): 优化按需加载与运行时开销
```

两个提交都在临时事务分支成功创建并通过检查后，Auto Release 才会把它们一起推送。无法可靠分类时自动退回一个提交，不会为了增加提交数量强行拆分。

### 4. Release：正式发布

适合发布稳定版本，例如 `v1.2.3`。

Auto Release 会按顺序执行：

1. 检查项目、分支、远程仓库和目标版本。
2. 更新项目中的版本文件。
3. 运行测试和本地构建。
4. 检查构建产物与敏感文件。
5. 提交版本变更。
6. 创建并原子推送 Git 标签。
7. 等待 GitHub Actions 构建各平台正式包。
8. 校验产物完整性。
9. 公开已经验证的 GitHub Release。

任何关键步骤失败都会停止；不会强推、覆盖旧标签或公开不完整的 Release。

## 首次使用会生成什么

完整发布模式通常会在你的项目中生成两个文件：

```text
.codex-release.json
.github/workflows/release.yml
```

- `.codex-release.json`：记录这个项目如何读取版本、测试、构建和发布。
- `release.yml`：标签触发的 GitHub Actions 正式发布工作流。

这两个文件属于你的项目，建议与代码一起提交。

如果只执行本地打包，Auto Release 只生成本地构建配置，不会创建 GitHub 工作流。

## 不会覆盖你的工作流

如果 `.github/workflows/release.yml` 已经由你维护，Auto Release 默认停止，不会直接覆盖。

你可以选择：

- **兼容复用**：现有工作流已经具备标签触发、发布权限和草稿 Release 能力时直接使用。
- **另建工作流**：保留原文件，创建 `.github/workflows/auto-release.yml`。
- **停止操作**：什么都不改，由你决定后续方案。

由 Auto Release 自己生成并带有托管标记的工作流，才允许后续自动更新。

## 常见问题

### 适用于所有项目吗？

不是“任何项目都无需配置”。它能自动处理上表中的 12 类常见项目。复杂单体仓库、多种项目清单并存或自定义构建系统，可能需要明确指定项目类型或调整 `.codex-release.json`。

### 会自动创建 GitHub Actions 吗？

会。选择正式发布或要求创建发布工作流时会生成；只做本地打包时不会生成。

### 一次能发布多少个安装包？

数量由项目类型决定。例如 Tauri 会生成五类桌面目标，Go 会生成六个系统/架构目标；Node.js 通常生成一个 `.tgz`。其他类型按照各自平台矩阵生成。

### 会改我的版本号吗？

`LocalBuild` 不会。只有正式 `Release` 才会更新版本。

### 会覆盖已有标签或强制推送吗？

不会。已有本地或远程标签、远程分叉、构建失败都会让发布停止。

### 提交信息必须是英文吗？

不需要全部使用英文。Auto Release 优先沿用仓库最近的提交格式；使用 Conventional Commits 时采用英文类型加中文说明，例如 `feat: 新增导出功能`。

## 高级用法

<details>
<summary>查看 PowerShell 命令</summary>

```powershell
$setup = "$env:USERPROFILE\.codex\skills\auto-release\scripts\setup-project.ps1"
$invoke = "$env:USERPROFILE\.codex\skills\auto-release\scripts\invoke-release.ps1"

# 识别项目，只读
& $setup -Mode Detect -RepositoryRoot "<仓库根目录>"

# 只生成本地构建配置
& $setup -Mode GenerateLocal -RepositoryRoot "<仓库根目录>"

# 生成完整配置与 GitHub Actions
& $setup -Mode Generate -RepositoryRoot "<仓库根目录>"

# 校验现有配置和工作流
& $setup -Mode Validate -RepositoryRoot "<仓库根目录>"

# 本地测试打包
& $invoke -Operation LocalBuild -RepositoryRoot "<仓库根目录>"

# 强制重新打包
& $invoke -Operation LocalBuild -ForceRebuild -RepositoryRoot "<仓库根目录>"

# 只读审计 Git ignore
& $invoke -Operation Ignore -IgnoreMode Audit -RepositoryRoot "<仓库根目录>"

# 补全规则并停止跟踪生成文件，但保留本地文件
& $invoke -Operation Ignore -IgnoreMode ApplyAndUntrack -RepositoryRoot "<仓库根目录>"

# 提交并推送
& $invoke -Operation CommitPush -Summary "chore: 更新项目" -RepositoryRoot "<仓库根目录>"

# 按 Codex 生成的计划创建多个提交并统一推送
& $invoke -Operation CommitPush -CommitStrategy AutoSplit `
  -CommitPlanPath "<仓库根目录>/.git/auto-release/commit-plan.json" `
  -RepositoryRoot "<仓库根目录>"

# 正式发布
& $invoke -Operation Release -Version v1.2.3 -Summary "chore(release): 发布 v1.2.3" `
  -ReleaseNotes "<中文 Release Notes>" -RepositoryRoot "<仓库根目录>"
```

常用选项：

- `-WhatIf`：只预览，不修改文件、Git 或 GitHub。
- `-OutputFormat Json`：输出适合脚本处理的 JSON。
- `-CommitStrategy AutoSplit`：按计划创建多个事务化提交并统一推送。
- `-IgnoreMode Audit|Apply|ApplyAndUntrack`：检查、应用或应用并停止跟踪。
- `-ProjectType`：多种项目清单并存时明确指定类型。
- `-WorkflowPolicy ReuseCompatible`：复用兼容的人工工作流。
- `-WorkflowPolicy CreateSeparate`：保留人工工作流并新建发布工作流。

</details>

完整配置字段见 [`skills/auto-release/references/config.md`](skills/auto-release/references/config.md)。

## 环境要求

- Windows PowerShell 5.1 或 PowerShell 7+
- Git
- Python（安装 Skill 或发布 Python 项目时需要）
- 项目自身需要的构建工具，例如 Node.js、Go、Rust、.NET SDK、JDK、Flutter 或 Docker
- GitHub CLI `gh`（正式发布到 GitHub 时需要）

## 开发与验证

```powershell
& ".\skills\auto-release\tests\validate.ps1"
```

## License

[MIT](LICENSE)
