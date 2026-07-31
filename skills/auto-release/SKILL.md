---
name: auto-release
description: Detects and configures common application, library, native, mobile, desktop, container, and Codex Skill repositories, then provides audience-aware README creation, optimization, and complete bilingual Chinese/English synchronization, local test builds, deep .gitignore audits and safe rule completion, Conventional Commits single or grouped commit-and-push, formal GitHub releases, dry-run previews, and JSON results. Supports Tauri, Node.js, Go, Python, Rust, .NET, Java, CMake, Flutter, Android, Electron, and Docker. Use when the user asks to create, restructure, audit, optimize, or translate a README/自述文件, including a complete English or bilingual version; build locally without changing version; inspect or complete Git ignore rules; stop tracking generated files without deleting them; classify changes into coherent commits and push them together; configure release automation; or publish a semantic version such as v1.2.3.
---

# Auto Release

只操作用户当前指定的 Git 仓库。不要猜测或复用其他仓库的配置，不要写入 Token、密钥或账号凭据，也不要把“本地打包”解释为正式发布。

## 选择操作

用户未明确操作时，显示以下五项并等待选择：

| 操作 | 适用请求 | 必须读取 |
|---|---|---|
| `README` | 创建、重构、审计、优化或制作中英文 README | [README 参考](references/readme.md) |
| `LocalBuild` | 本地测试或打包，不改版本 | [LocalBuild 参考](references/local-build.md) |
| `Ignore` | 审计或补全 `.gitignore`，安全停止跟踪本地文件 | [Ignore 参考](references/ignore.md) |
| `CommitPush` | 提交全部安全更改并推送，必要时拆成多提交 | [CommitPush 参考](references/commit-push.md) |
| `Release` | 发布 `vX.Y.Z`、等待工作流并公开 GitHub Release | [Release 参考](references/release.md) 与 [配置参考](references/config.md) |

用户只说“忽略”时选择 `Ignore Audit`，先展示计划，不直接修改。用户只要求建议、检查或评价时保持只读；只有明确要求执行对应写操作时才修改、提交、推送或发布。

用户要求创建英文自述文件或中英文版本时选择 `README`：先按源文档完成目标语言全文并验证内容一致性，再添加双向语言入口；只有语言链接或翻译占位不算完成。

仓库尚无任何 README 时，按用户请求的语言建立主入口：只要求英文时直接创建英文 `README.md`；要求中英文双语时创建主 `README.md` 与 `README_EN.md`，除非仓库已有其他明确命名约定。不要创建缺少主 README 的孤立 `README_EN.md`。

## 初始化与验证

在仓库根目录使用独立初始化器：

```powershell
$setup = "$env:USERPROFILE\.codex\skills\auto-release\scripts\setup-project.ps1"

& $setup -Mode Detect -RepositoryRoot "<仓库根目录>"
& $setup -Mode GenerateLocal -RepositoryRoot "<仓库根目录>"
& $setup -Mode Generate -RepositoryRoot "<仓库根目录>"
& $setup -Mode Validate -RepositoryRoot "<仓库根目录>"
```

- `Detect` 只读。
- `GenerateLocal` 只生成本机 LocalBuild 配置，不接触 GitHub 工作流。
- `Generate` 生成 schema v2 本机配置和标签触发工作流。
- `Validate` 检查现有配置、工作流和产物契约。

自动支持 Tauri、Node.js、Go、Python、Rust、.NET、Java、CMake、Flutter、Android、Electron 和 Docker。专用应用类型优先；其他多生态清单并存时要求 `-ProjectType`。配置字段、项目策略和人工工作流处理规则见 [配置参考](references/config.md)。

生成器只能覆盖带 Auto Release 或旧版 Project Release Automator 托管标记的配置/工作流；遇到人工文件必须停止。重复生成必须幂等。`.codex-release.json` 是可再生的本机配置，必须保留在磁盘、精确忽略且不得提交；旧仓库仍跟踪它时，先执行 `Ignore ApplyAndUntrack`。

## 统一入口

```powershell
$invoke = "$env:USERPROFILE\.codex\skills\auto-release\scripts\invoke-release.ps1"
```

所有脚本都接收明确的 `-RepositoryRoot`。用户要求预览时传入 `-WhatIf`，不得产生配置、版本、构建产物、Git 或 GitHub 副作用。机器调用时传入 `-OutputFormat Json`，只依赖最后一行 JSON；失败结果包含 `stage`、`errorCode` 和 `message`。

执行 `CommitPush` 或 `Release` 前，检查触发本次操作的用户提示词。用户显式指定提交语言时优先采用；否则中文提示传 `-PromptLanguage Chinese`，英文提示传 `-PromptLanguage English`，混合提示按主要指令语言判断，仍无法确定时传 `Auto` 以回退到仓库历史。所有提交标题固定使用 Conventional Commits：`type(scope): 描述` 或 `type: 描述`；类型和 scope 保持英文，只根据提示词切换冒号后描述的语言。`AutoSplit` 的全部组使用同一语言。

## 不可绕过的保护

- 只有 `CommitPush` 允许全量暂存；`Release` 启动时必须是干净工作区，并且只能精确暂存本次发布生成的版本文件和托管自动化文件。发现普通改动时停止，提示用户另行执行 `CommitPush`。其他操作禁止 `git add .`、`git add -A` 或等价操作。
- 禁止 `--force` 强制推送、移动或覆盖版本标签、自动合并、自动变基和自动解决远端分叉。
- 禁止删除用户本地文件、宽泛执行 `git rm --cached .` 或自动重写历史。
- 禁止提交未在当前任务中确认的本地产物或疑似凭据。
- 发布前必须绑定配置的 GitHub 仓库，验证标签指向、工作流结果以及远端资产大小和 SHA256；任何失败都不得公开草稿。
- 用户没有明确要求提交、推送或发布时，保留改动供其审阅。

## 最终汇报

只汇报决定性结果：执行的操作、关键安全决策、改动文件、验证结果、产物绝对路径与 SHA256、提交、标签、工作流和 Release URL。失败时报告停止阶段、已保留的远端状态和可复现错误。
