# Release 正式发布

只在用户明确要求正式发布语义版本时读取本文件；同时读取 [配置参考](config.md)。不得把“本地打包”解释为 Release。

## 前置输入

- 稳定语义版本 `vX.Y.Z`。
- 符合仓库提交风格且描述语言与触发提示词一致的单行 `Summary`。
- 以配置标题开头、数量符合限制的中文 `ReleaseNotes`。
- 干净且可解释的发布配置、标签触发工作流和远端状态。

```powershell
$invoke = "$env:USERPROFILE\.codex\skills\auto-release\scripts\invoke-release.ps1"
$notes = @"
## 更新内容

- 新增：第一项用户可感知变化。
- 修复：第二项用户可感知变化。
"@

powershell.exe -NoProfile -ExecutionPolicy Bypass -File $invoke `
  -Operation Release -Version vX.Y.Z `
  -PromptLanguage Chinese `
  -Summary "chore(release): 一句中文总结" `
  -ReleaseNotes $notes -RepositoryRoot "<仓库根目录>"
```

先用 `-WhatIf` 预览。正式执行固定为 `Plan -> Prepare -> Commit -> Publish`。

## Plan

- 校验仓库根目录、配置分支、配置远端和可选 `remoteUrlPattern`。
- 读取当前版本、状态、最近稳定标签后的提交和当前差异。
- 分析提交风格并验证 `Summary`。
- 根据 `PromptLanguage` 验证提交描述语言；判定优先级和混合提示规则与 [CommitPush 参考](commit-push.md) 一致。
- 只输出版本、构建、产物、工作流、Release 和原子 push 计划；不暂存或修改文件。

## Prepare 与 Commit

- 同步版本文件；正则替换数量必须精确匹配配置。
- 运行完整测试与构建，整理产物并计算 SHA256；失败时回滚脚本引入的版本修改。
- 并行任务首个失败后终止本次启动的兄弟进程。
- 本地构建收据、源码指纹和产物哈希全部有效时可跳过重复本地程序构建；GitHub Actions 仍重新构建正式包。
- 构建期间源码变化时用新状态重建一次；继续变化则停止。
- 提交前重新验证源码指纹和敏感文件；没有变化时不创建空提交，但 `HEAD` 主题仍必须等于 `Summary`。

## Publish

- 从 `githubRepository` 读取 `OWNER/REPO` 或 `HOST/OWNER/REPO`；缺失时从配置远端 URL 推导。所有 `gh run`、`gh release` 调用都显式传入 `--repo`。
- 创建新标签时使用 annotated tag，并原子推送配置分支与标签；禁止强制更新。
- 同版本标签已存在时，只在本地和远端标签都解析到当前 `HEAD` 时续跑。任一标签指向其他提交立即停止。
- 结构化轮询匹配标签和 `HEAD` SHA 的 GitHub Actions；本地等待失败时不取消远端工作流，也不公开草稿。

## Release 与资产完整性

- `publish-draft`：读取工作流生成的草稿；校验必需名称、上传状态、非零大小和 GitHub SHA256，下载全部资产复核大小与 SHA256 后公开。
- `create`：先用 `--draft --verify-tag` 创建草稿并上传 `uploadAssets`；远端名称、数量、大小和 SHA256 必须与本地文件一致，再下载复核，最后用 `--verify-tag --draft=false` 公开。
- `none`：只推送分支和标签；统一 `Release` 操作拒绝该模式。
- 已公开的同版本 Release 只做完整性复核并作为幂等成功返回，不再编辑。
- 缺少 digest、空资产、名称缺失、下载内容不符、工作流失败或公开前验证失败都必须停止，保留草稿。

## 强制保护

- 禁止使用任何 `--force`、移动标签、覆盖标签、自动合并或自动变基。
- 禁止在工作流或资产验证失败时公开 Release。
- `gh` 缺失或对应主机未登录时停止。
- 发布后发现问题时创建新的补丁版本，不修改旧版本。

## 完成标准

报告提交 SHA、版本标签、匹配工作流 URL、Release URL，以及每个已验证资产的名称、绝对本地路径（存在时）、长度和 SHA256。失败时报告停止阶段和可复现错误。
