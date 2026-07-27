# Auto Release

[![License: MIT](https://img.shields.io/github/license/suzeccc/auto-release?style=flat-square)](LICENSE)

面向 Codex 的项目发布 Skill：从 README 优化、本地构建、Git 忽略审计，到分类提交和 GitHub Release，把常见仓库操作收敛成一套有明确边界的工作流。

它支持 12 类应用、库、桌面、移动、原生和容器项目。你只需告诉 Codex 想完成什么；Auto Release 会先识别当前仓库，再选择对应的配置、构建和发布策略。

## 快速开始

### 1. 安装

在 PowerShell 中运行：

```powershell
python -X utf8 "$env:USERPROFILE\.codex\skills\.system\skill-installer\scripts\install-skill-from-github.py" `
  --repo suzeccc/auto-release `
  --path skills/auto-release
```

安装完成后，新建一个 Codex 任务，让 Skill 列表刷新。

### 2. 直接告诉 Codex 目标

```text
优化这个项目的 README
本地打包，不要改版本，也不要提交
检查 Git 忽略规则
检查当前修改，分类提交后统一推送
正式发布 v1.2.3
```

如果目标不明确，Codex 会让你从 `README`、`LocalBuild`、`Ignore`、`CommitPush`、`Release` 中选择。只说“忽略”时默认执行只读审计，不会直接修改 `.gitignore`。

## 五种工作流

| 操作 | 适合做什么 | 默认会改什么 |
|---|---|---|
| `README` | 创建、重构或审计项目自述文件 | 只修改文档，不暂存、不提交、不推送 |
| `LocalBuild` | 在本机验证项目能否构建 | 可生成本地构建配置和 `output/` 产物；不改版本和 Git |
| `Ignore` | 检查缺失规则、敏感路径和已跟踪生成文件 | 默认只生成审计计划；应用规则需要确认 |
| `CommitPush` | 提交当前安全改动并推送当前分支 | 创建一个或多个 Git 提交，然后执行一次推送 |
| `Release` | 发布稳定语义版本 | 可更新版本、构建、提交、推送标签并操作 GitHub Release |

### README

Auto Release 先识别项目类型、主要读者及其首要任务，再决定 README 的内容顺序。它会核对仓库中的功能、命令、链接、图片、许可证和状态，只在存在可靠数据源时添加徽章。

详细 API、内部实现和长篇故障排查会保留在 `docs/` 或引用文档中，避免让 README 变成资料堆积页。

### LocalBuild

本地构建不会修改版本、创建提交或访问 GitHub。构建产物统一复制到：

```text
output/<项目名><扩展名>
```

源码指纹和产物 SHA256 都未变化时，可以复用上次结果；明确要求“强制重新打包”时会忽略缓存。

### Ignore

Ignore 会检查根目录和嵌套 `.gitignore`、当前 Git 状态、工具链缓存、构建输出、Agent/IDE 本地状态、测试报告和需要人工判断的路径。对于 Codex Skill 源码仓库，它会识别有效 `SKILL.md`，保护整个 Skill 根目录，并单独处理 `.install-test/` 本地安装验证沙箱。

- `Audit`：只生成计划。
- `Apply`：补全已确认的规则。
- `ApplyAndUntrack`：补全规则，并停止跟踪计划中确认的文件；本地文件仍然保留。

Ignore 不负责提交或推送，也不会自动重写 Git 历史。计划细节见 [Ignore 审计与应用](skills/auto-release/references/ignore.md)。

### CommitPush

CommitPush 会同时检查已暂存、未暂存、删除和未跟踪文件，并执行内置的疑似凭据检查。它会分析仓库最近的提交风格；无法可靠确定时，回退到 Conventional Commits。

当改动包含多个独立目的时，`AutoSplit` 可以按计划创建 2～4 个事务化提交。所有分组成功后才更新原分支并统一推送；无法可靠分类时退回单提交。

```text
feat: 新增自动发布工作流
fix(release): 修复标签发布失败
docs: 更新安装说明
```

### Release

Release 按 `Plan → Prepare → Commit → Publish` 执行：

1. 校验仓库、分支、远程、版本和发布说明。
2. 更新版本文件并运行项目测试与构建。
3. 检查本地构建结果和待提交内容。
4. 提交版本变更，创建并原子推送标签。
5. 等待配置的 GitHub Actions。
6. 按配置检查所需发布资产，并创建或公开 GitHub Release。

生成的发布工作流使用草稿 Release；如果项目使用自定义 `.codex-release.json` 或人工工作流，应在正式发布前审查对应的发布模式和资产规则。

## 支持的项目

| 项目类型 | 自动识别依据 | 典型正式产物 |
|---|---|---|
| Tauri | `src-tauri/tauri.conf.json` | Windows 安装包、macOS DMG、Linux 包 |
| Node.js | `package.json` | npm `.tgz` |
| Go | `go.mod` | Windows、Linux、macOS amd64/arm64 程序 |
| Python | `pyproject.toml`、`setup.py` 或 `setup.cfg` | wheel、sdist |
| Rust | `Cargo.toml` | `.crate` |
| .NET | `.csproj` | `.nupkg` |
| Java | `pom.xml` 或 Gradle 构建文件 | `.jar` |
| CMake | `CMakeLists.txt` | Windows、Linux、macOS 多架构压缩包 |
| Flutter | `pubspec.yaml` | 移动端、桌面端和 Web 构建 |
| Android | Android Gradle 项目 | APK、AAB |
| Electron | Electron `package.json` | Windows、Linux、macOS 多架构压缩包 |
| Docker | `Dockerfile` | GHCR 多架构镜像和摘要清单 |

专用应用类型优先识别。多个普通项目清单并存时，Auto Release 会停止并要求显式选择 `-ProjectType`，不会依赖不透明的猜测顺序。

## 首次使用与项目文件

Auto Release 会按操作逐步准备配置：

- 只做本地构建时，生成本地构建所需的 `.codex-release.json`，不创建 GitHub 工作流。
- 需要正式发布时，补全发布配置并创建标签触发的工作流。

完整发布配置通常包含：

```text
.codex-release.json
.github/workflows/release.yml
```

这两个文件属于项目，应与代码一起评审和提交。运行收据、Ignore 计划和分类提交计划存放在 `.git/auto-release/`，不会成为仓库内容。

## 现有工作流保护

如果目标发布工作流已经存在但没有 Auto Release 托管标记，生成器默认停止，不会直接覆盖。你可以明确选择：

- `ReuseCompatible`：复用已经满足标签触发、权限和草稿 Release 要求的人工工作流。
- `CreateSeparate`：保留原工作流，创建 `.github/workflows/auto-release.yml`。
- `Stop`：保持仓库不变，由你先处理冲突。

只有 Auto Release 自己生成并带有托管标记的文件，后续才允许自动更新。

## PowerShell 入口

日常使用直接告诉 Codex 目标即可。需要调试、集成或脚本化时，可以调用底层入口。

<details>
<summary>项目识别与初始化</summary>

```powershell
$setup = "$env:USERPROFILE\.codex\skills\auto-release\scripts\setup-project.ps1"

# 只读识别
& $setup -Mode Detect -RepositoryRoot "<仓库根目录>"

# 只生成本地构建配置
& $setup -Mode GenerateLocal -RepositoryRoot "<仓库根目录>"

# 生成完整配置和发布工作流
& $setup -Mode Generate -RepositoryRoot "<仓库根目录>"

# 校验现有配置
& $setup -Mode Validate -RepositoryRoot "<仓库根目录>"
```

</details>

<details>
<summary>构建、Ignore、提交与发布</summary>

```powershell
$invoke = "$env:USERPROFILE\.codex\skills\auto-release\scripts\invoke-release.ps1"

# 本地构建
& $invoke -Operation LocalBuild -RepositoryRoot "<仓库根目录>"
& $invoke -Operation LocalBuild -ForceRebuild -RepositoryRoot "<仓库根目录>"

# Ignore 审计
& $invoke -Operation Ignore -IgnoreMode Audit -RepositoryRoot "<仓库根目录>"

# 应用已确认计划并停止跟踪生成文件
& $invoke -Operation Ignore -IgnoreMode ApplyAndUntrack -RepositoryRoot "<仓库根目录>"

# 单提交并推送
& $invoke -Operation CommitPush `
  -PromptLanguage Chinese `
  -Summary "docs: 更新项目说明" `
  -RepositoryRoot "<仓库根目录>"

# 按 Codex 生成的计划分类提交并统一推送
& $invoke -Operation CommitPush `
  -CommitStrategy AutoSplit `
  -PromptLanguage Chinese `
  -CommitPlanPath "<仓库根目录>/.git/auto-release/commit-plan.json" `
  -RepositoryRoot "<仓库根目录>"

$notes = @"
## 更新内容

- 新增：第一项用户可感知变化。
- 修复：第二项用户可感知变化。
"@

# 正式发布
& $invoke -Operation Release `
  -Version v1.2.3 `
  -PromptLanguage Chinese `
  -Summary "chore(release): 发布 v1.2.3" `
  -ReleaseNotes $notes `
  -RepositoryRoot "<仓库根目录>"
```

</details>

提交语言跟随触发操作的用户提示词：中文提示使用 `-PromptLanguage Chinese`，英文提示使用 `English`；用户明确指定语言时优先，混合提示无法可靠判断时使用 `Auto` 分析仓库历史。Conventional Commit 的类型和 scope 保持仓库规范，只切换描述语言；分类提交中的全部提交使用同一种语言。

常用选项：

- `-WhatIf`：预览统一入口操作，不修改文件、Git 或 GitHub。
- `-OutputFormat Json`：输出适合自动化读取的单行 JSON 结果。
- `-ProjectType`：多种项目清单并存时显式选择类型。
- `-WorkflowPolicy ReuseCompatible|CreateSeparate`：决定如何处理人工发布工作流。

完整字段和计划格式见 [`.codex-release.json` 配置参考](skills/auto-release/references/config.md)。

## 安全边界

- 不强制推送，不移动或覆盖已有版本标签。
- 远程分支领先或分叉时停止，不自动合并或变基。
- `Ignore` 默认只读；应用和停止跟踪需要明确确认。
- `CommitPush` 和 `Release` 会执行启发式敏感文件检查，但不能替代人工审查和专用密钥扫描工具。
- `Release` 会修改版本、Git 和 GitHub；正式执行前可先使用 `-WhatIf` 查看计划。
- 人工维护的工作流默认保持不变。

## 环境要求

- Codex
- Windows PowerShell 5.1 或 PowerShell 7+
- Git
- Python（安装 Skill 或发布 Python 项目时需要）
- 目标项目自己的构建工具，例如 Node.js、Go、Rust、.NET SDK、JDK、Flutter 或 Docker
- GitHub CLI `gh`（访问 GitHub Actions 或 GitHub Release 时需要）

## 开发与验证

仓库的契约测试会检查 Skill 结构、12 类项目配置、工作流模板和主要操作路径：

```powershell
& ".\skills\auto-release\tests\validate.ps1"
```

维护 README 时可参考 [README 优化参考](skills/auto-release/references/readme.md)。

## License

[MIT](LICENSE)
