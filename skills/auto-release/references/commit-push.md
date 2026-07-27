# CommitPush 提交与推送

只在用户明确要求提交并推送当前仓库时读取本文件。该操作允许等价于 `git add -A` 的全量暂存，但仍遵守 `.gitignore`，并覆盖已暂存、未暂存、删除和未跟踪更改。

## 单提交入口

```powershell
$invoke = "$env:USERPROFILE\.codex\skills\auto-release\scripts\invoke-release.ps1"
$style = "$env:USERPROFILE\.codex\skills\auto-release\scripts\commit-style.ps1"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File $style -RepositoryRoot "<仓库根目录>"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $invoke `
  -Operation CommitPush -PromptLanguage Chinese `
  -Summary "fix(auth): 修复登录失败问题" `
  -RepositoryRoot "<仓库根目录>"
```

先用 `-WhatIf -OutputFormat Json` 预览；结果在兼容字段 `commitStyle` 中返回固定格式及策略归一化原因。

## 提交格式

- 所有 `CommitPush`、`AutoSplit` 和 `Release` 标题都必须使用 Conventional Commits。
- 允许 `type: 描述`、`type(scope): 描述`，以及破坏性变更形式 `type(scope)!: 描述`。
- 类型使用小写英文；常用值包括 `feat`、`fix`、`docs`、`refactor`、`test`、`build`、`ci`、`perf` 和 `chore`。scope 可省略。
- 不接受纯文本、`[type]`、工单前缀或 Gitmoji 作为标题前缀。
- 新配置固定使用 `commit.policy: conventional`。旧配置中的 `auto` 和 `off` 仅为兼容而可读取，运行时都会归一化为 `conventional`，不能关闭校验。

## 提示词语言

- 用户显式要求中文或英文提交信息时，以该要求为准。
- 否则检查触发当前 `CommitPush` 的用户提示词：中文主指令使用 `Chinese`，英文主指令使用 `English`；混合内容按主要指令语言判断，无法可靠判断时使用 `Auto`。
- `Auto` 分析最近提交描述的主要语言；样本不足、并列或置信度不足时回退到英文。
- Conventional Commit 的 `feat`、`fix`、`docs`、`chore` 等类型仍使用标准英文；只要求冒号后的描述匹配提示词语言。
- `AutoSplit` 的每个 `groups[].summary` 必须使用同一个 `PromptLanguage`，不得在一轮提交中混用中英文描述。

## 多提交策略

改动包含两个以上独立目的时，生成 `.git/auto-release/commit-plan.json` 并使用 `AutoSplit`：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $invoke `
  -Operation CommitPush -CommitStrategy AutoSplit -PromptLanguage Chinese `
  -CommitPlanPath "<仓库根目录>/.git/auto-release/commit-plan.json" `
  -RepositoryRoot "<仓库根目录>" -WhatIf
```

计划必须精确覆盖全部改动，不使用通配符；同一文件默认只属于一组。按 diff 语义分类，不只按目录：实现与对应测试、清单与锁文件、源文件与生成文件必须同组。默认保持 2 至 4 组；微小、低置信度或循环依赖的组应合并，无法可靠分类时回退到 `Single`。完整 schema 见 [配置参考](config.md)。

执行器在临时 `auto-release/transaction-*` 分支依次提交。任何组失败时回到原分支，恢复原索引和未提交改动；全部成功后才快进原分支并执行一次 push。推送前远端变化时停止，保留已验证的本地提交供安全重试。

## 安全门槛

- 发现未解决冲突、远端领先/分叉、明显凭据文件、私钥或常见 Token 时停止。
- 不自动合并、变基或强制推送。
- `.codex-release.json` 必须已被忽略且不再被跟踪；迁移提交可以记录其索引删除，但本地文件必须保留。
- 失败时恢复原暂存区；不得借提交操作删除用户的本地生成物。

## 完成标准

报告 Conventional Commits 格式、提交数量、每个提交 SHA/主题、分支和 push 结果。不要在 `CommitPush` 后自动创建标签或 Release。
