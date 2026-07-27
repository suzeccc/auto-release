# LocalBuild 本地验证

只在用户要求本地测试、构建或打包且没有要求正式发布时读取本文件。`LocalBuild` 不修改项目版本，不提交、不推送、不创建标签，也不访问 GitHub Release。

## 入口

```powershell
$invoke = "$env:USERPROFILE\.codex\skills\auto-release\scripts\invoke-release.ps1"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File $invoke `
  -Operation LocalBuild -RepositoryRoot "<仓库根目录>"
```

- 用户要求预览时追加 `-WhatIf`；不得生成配置、安装依赖、构建或写入产物。
- 机器调用时追加 `-OutputFormat Json`，只依赖最后一行 JSON。
- 用户明确要求重新打包时追加 `-ForceRebuild`。

## 首次运行

缺少 `.codex-release.json` 时先运行：

```powershell
$setup = "$env:USERPROFILE\.codex\skills\auto-release\scripts\setup-project.ps1"
& $setup -Mode GenerateLocal -RepositoryRoot "<仓库根目录>"
```

`GenerateLocal` 只创建被忽略的本机配置并补充精确 `.gitignore` 规则；不得读取、创建或覆盖 GitHub 工作流。以后选择 `Release` 时再用完整 `Generate` 升级。

## 执行契约

- 使用 `prepare.localCommands`；旧配置未声明时回退到 `prepare.commands`。
- 根据 `prepare.bootstrapInputs`、依赖命令和 `prepare.bootstrapRequiredPaths` 计算依赖缓存，只在输入变化或依赖状态缺失时执行 `bootstrapCommands`。
- 使用快速本地策略：Tauri 不生成安装器，Python 只生成 wheel，Rust 执行 release build，.NET 执行 build，Electron 使用当前平台构建。
- 只校验本地版本源、命令和产物；不得因工作流缺少标签触发器、权限或草稿 Release 而失败。

## 输出与复用

- 保留构建工具原始产物，并复制到 `<仓库根目录>/output/<项目名><扩展名>`；目录和文件名不包含版本或标签。
- 目标不存在时创建，存在时覆盖；文件被占用时停止，不创建 `-2`、`-3` 备用文件。
- 只按配置或上次收据中的完整 EXE 路径终止进程，不扫描或终止 `output` 中的无关程序。
- 在 `.git/auto-release/local-build.json` 记录忽略版本值的源码指纹、底层执行器返回的精确产物、长度和 SHA256。
- 收据、源码指纹和产物哈希都有效时直接复用；构建后删除上次由 Skill 管理但本次不再生成的旧输出。

## 完成标准

报告是否复用缓存，以及每个规范输出的绝对路径、长度和 SHA256。失败时报告 `stage`、`errorCode` 和可复现消息；不要自动转为提交或正式发布。
