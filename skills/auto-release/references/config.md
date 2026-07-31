# `.codex-release.json` 配置参考

配置位于 Git 仓库根目录，但属于可再生的本机 Skill 配置，不是公共项目清单。生成器会把其精确根路径加入 `.gitignore`；提交器读取它但不提交其内容。所有相对路径都以仓库根目录为基准，所有正则表达式使用 .NET 语法。

## 目录

- [自动生成](#自动生成)
- [用户操作入口](#用户操作入口)
- [完整结构](#完整结构)
- [字段规则](#字段规则)
- [自动生成的项目策略](#自动生成的项目策略)
- [托管工作流保护](#托管工作流保护)
- [最小无工作流示例](#最小无工作流示例)

## 自动生成

初始化器支持三种模式：

```powershell
$setup = "$env:USERPROFILE\.codex\skills\auto-release\scripts\setup-project.ps1"
& $setup -Mode Detect -RepositoryRoot "<仓库根目录>"
& $setup -Mode GenerateLocal -RepositoryRoot "<仓库根目录>"
& $setup -Mode Generate -RepositoryRoot "<仓库根目录>"
& $setup -Mode Validate -RepositoryRoot "<仓库根目录>"
```

- `Detect`：只读识别支持的项目类型，并报告版本源、包管理器和构建入口。
- `GenerateLocal`：生成被忽略的本地构建配置，不检查、不创建也不覆盖 GitHub 工作流；正式发布时可升级为完整配置。
- `Generate`：生成被忽略的 schema v2 本机配置和需要提交的标签触发 GitHub Actions 工作流。
- `Validate`：检查配置、版本源、工作流标记、标签触发器、权限、草稿 Release 和产物规则。

`-ProjectType` 支持 `auto`、`tauri`、`node`、`go`、`python`、`rust`、`dotnet`、`java`、`cmake`、`flutter`、`android`、`electron` 和 `docker`。专用应用类型优先识别；其他项目存在多个生态清单时必须显式指定类型。

现有人工工作流通过 `-ExistingWorkflowPolicy` 处理：

- `Stop`：默认停止，不写入任何文件。
- `CreateSeparate`：保留人工工作流，创建 `.github/workflows/auto-release.yml`。
- `ReuseCompatible`：检查标签触发、写权限和草稿 Release；兼容后复用，并写入 `managedWorkflow: false`。

## 用户操作入口

统一脚本为 `scripts/invoke-release.ps1`：

```powershell
# 本地测试构建，不修改版本
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\invoke-release.ps1 -Operation LocalBuild

# 强制重新构建本地程序
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\invoke-release.ps1 -Operation LocalBuild -ForceRebuild

# 无副作用预演
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\invoke-release.ps1 -Operation LocalBuild -WhatIf

# 单行 JSON 输出
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\invoke-release.ps1 -Operation LocalBuild -OutputFormat Json

# 深度检查缺失的 Git ignore 规则；默认只读工作区
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\invoke-release.ps1 -Operation Ignore -IgnoreMode Audit

# 提交更改区和暂存区的全部安全更改，并推送当前分支
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\invoke-release.ps1 -Operation CommitPush -PromptLanguage Chinese -Summary "chore: 整理项目改动"

# 按计划创建多个提交，全部成功后统一推送
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\invoke-release.ps1 `
  -Operation CommitPush -CommitStrategy AutoSplit -PromptLanguage Chinese `
  -CommitPlanPath ".git/auto-release/commit-plan.json"

# 更新版本、提交推送、构建全部包并发布 GitHub
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\invoke-release.ps1 -Operation Release -Version v1.2.3 `
  -PromptLanguage Chinese -Summary "chore(release): 发布新版本" -ReleaseNotes "<中文 Release Notes>"
```

`LocalBuild` 调用 `prepare.localCommands`，未声明时兼容回退到 `prepare.commands`；它不运行 `version.updates`，也不验证 GitHub 工作流的标签触发器、发布权限或草稿 Release。`prepare.bootstrapCommands` 根据 `prepare.bootstrapInputs` 的哈希缓存，输入未变化时不重复安装依赖。构建产物统一复制到 `prepare.localOutputDirectory`，默认是 `output`；目标文件使用 `<projectName><扩展名>`，不含版本号，目录或文件不存在时自动创建。

`Ignore` 不依赖 `.codex-release.json`。审计会把该文件固定识别为本机配置；旧仓库已经跟踪它时，使用 `ApplyAndUntrack` 保留本地副本并精确停止跟踪。`Audit`、`Apply`、`ApplyAndUntrack` 的计划结构、安全边界和回滚规则见 [`ignore.md`](ignore.md)。

执行器只按完整路径终止配置产物和上次收据记录的 EXE，不扫描或终止输出目录中的无关程序。`prepare.localArtifacts` 控制本地快速构建产物，`prepare.artifacts` 控制正式构建产物；`prepare.localSearchRoots` 为无法提前确定完整文件名的本地产物提供受限搜索根目录。`localName` 可覆盖统一输出文件名。`prepare.localOutputDirectory` 必须是无版本、无标签占位符的稳定路径。草稿式 GitHub Release 的正式操作只把本地验证产物写入该规范目录，不采用 `artifacts[].destination` 中的版本路径；GitHub Actions 负责正式发布包。成功后在 `.git/auto-release/local-build.json` 保存忽略发布版本值的源文件指纹、底层执行器返回的精确产物清单和 SHA256，并删除上次由 Skill 管理、这次不再生成的旧输出。默认复用有效收据；`-ForceRebuild` 强制重新构建。正式发布提交前再次校验源码指纹，避免构建后变化的文件进入发布提交。

`CommitPush` 明确执行全量暂存，包含已暂存、未暂存、删除和未跟踪文件，并遵守 `.gitignore`。`Release` 不复用该行为：它要求启动时工作区干净，只精确提交从该基准生成的托管自动化文件和 `version.updates[].path` 声明的版本文件；其他改动会中止发布并要求单独使用 `CommitPush`。`.codex-release.json` 必须已被忽略且不再被 Git 跟踪；迁移提交只记录其索引删除，本地文件保持不变。两种操作提交前都拒绝 Git 冲突、明显凭据文件、私钥和常见 Token。

`CommitPush` 默认使用兼容的 `Single` 策略。需要把一轮改动拆成多个语义提交时，Codex 先把计划写入 Git 元数据目录，再传入 `-CommitStrategy AutoSplit -CommitPlanPath <path>`。计划不会进入仓库，必须精确列出全部改动路径，不接受通配符，同一文件不能重复出现。默认最多 4 组，可用 `-MaxCommits` 在 2 至 8 之间调整。

```json
{
  "schemaVersion": 1,
  "baseHead": "完整的计划基准提交 SHA",
  "groups": [
    {
      "summary": "chore(repo): 整理仓库维护文件",
      "paths": [".gitignore", "previews/example.html"]
    },
    {
      "summary": "perf(frontend): 优化按需加载与运行时开销",
      "paths": ["package.json", "package-lock.json", "src/app.ts", "tests/app.test.ts"]
    }
  ]
}
```

每个 `summary` 都必须使用 Conventional Commits，并让冒号后的描述匹配统一的 `PromptLanguage`。类型和 scope 不参与语言判断。建议保持 2 至 4 组：实现和对应测试同组、清单和锁文件同组、源文件和生成文件同组；小组、低置信度组和相互依赖组应合并。执行器先验证计划和全部敏感文件，再在临时事务分支逐组运行暂存检查并提交。任一步失败时恢复原分支、原暂存区和全部工作区改动；全部成功后快进原分支并只推送一次。`-WhatIf -OutputFormat Json` 会在 `commitPlan` 返回规范化计划，并在 `commitLanguage` 返回语言来源和回退原因。

提交前可独立验证格式和提示词语言：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\commit-style.ps1 -RepositoryRoot .
```

提交格式固定为 `type(scope): 描述` 或 `type: 描述`，可用 `!` 标记破坏性变更；不再分析历史提交来切换格式。`PromptLanguage` 接受 `Chinese`、`English` 或 `Auto`；前两项来自当前用户提示词，只有 `Auto` 会读取最近提交的描述语言，并在无法确定时回退到英文。统一入口会再次校验 `Summary`，预演 JSON 分别在兼容字段 `commitStyle` 和 `commitLanguage` 中返回格式与语言结果。

生成的工作流首部包含以下托管标记：

```yaml
# Generated by Auto Release
# Template: node-v1
```

只有带托管标记的工作流和带 `automation.generator` 的配置才能被后续生成覆盖。人工维护的文件始终拒绝覆盖，且冲突检查发生在写入任何文件之前。

## 完整结构

```json
{
  "schemaVersion": 2,
  "projectType": "node",
  "automation": {
    "generator": "auto-release",
    "template": "node-v1",
    "managedWorkflow": true,
    "workflowFile": ".github/workflows/release.yml"
  },
  "projectName": "ExampleApp",
  "branch": "main",
  "remote": "origin",
  "githubRepository": "owner/repository",
  "remoteUrlPattern": "github\\.com[:/]owner/repository(?:\\.git)?$",
  "tagPrefix": "v",
  "commit": {
    "policy": "conventional",
    "analyzeCount": 30,
    "minimumSamples": 3,
    "confidenceThreshold": 0.6,
    "fallback": "conventional"
  },
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
    "localOutputDirectory": "output",
    "bootstrapInputs": ["package.json", "package-lock.json"],
    "bootstrapRequiredPaths": ["node_modules"],
    "bootstrapCommands": [
      { "name": "Install dependencies", "command": "npm ci" }
    ],
    "localCommands": [
      { "name": "Tests", "command": "npm test" },
      { "name": "Build", "command": "npm run build" },
      { "name": "Pack", "command": "if not exist dist mkdir dist && npm pack --pack-destination dist" }
    ],
    "localArtifacts": [],
    "localSearchRoots": ["dist"],
    "commands": [
      { "name": "Tests", "command": "npm test" },
      { "name": "Build", "command": "npm run build" },
      { "name": "Pack", "command": "if not exist dist mkdir dist && npm pack --pack-destination dist" }
    ],
    "artifacts": [
      {
        "source": "dist/example-app-{version}.tgz",
        "sha256": true
      }
    ]
  },
  "releaseNotes": {
    "heading": "## 更新内容",
    "minItems": 2,
    "maxItems": 6,
    "requireChinese": true
  },
  "publish": {
    "workflow": {
      "name": "Release",
      "event": "push",
      "findTimeoutSeconds": 120,
      "waitTimeoutMinutes": 90
    },
    "release": {
      "mode": "publish-draft",
      "title": "{projectName} {tag}",
      "requireDraft": true,
      "requiredAssets": [
        { "pattern": "(?i)^example-app-\\d+\\.\\d+\\.\\d+\\.tgz$", "label": "npm package" }
      ]
    }
  }
}
```

## 字段规则

- `schemaVersion`：发布执行器兼容 `1` 和 `2`；自动生成器使用 `2`。
- `projectType`：schema v2 使用上述十二种项目类型之一。
- `automation.generator`：新配置固定为 `auto-release`；验证和升级时兼容旧值 `project-release-automator`。
- `automation.template`：工作流模板标识，为 `<projectType>-v1`。
- `automation.managedWorkflow`：为 `true` 时，`Validate` 强制校验托管标记和模板一致性。
- `automation.workflowFile`：托管工作流的仓库相对路径。
- `projectName`、`branch`、`remote`：必填。
- `githubRepository`：可选；使用 `OWNER/REPO` 或 GitHub Enterprise 的 `HOST/OWNER/REPO`。未设置时从配置远端 URL 推导；无法可靠推导时正式发布停止。所有 `gh run`、`gh release` 命令都显式绑定该仓库。
- `remoteUrlPattern`：可选；设置后必须匹配 `git remote get-url <remote>`。
- `tagPrefix`：可选，默认 `v`。
- `commit.policy`：新配置固定为 `conventional`。旧配置中的 `auto` 和 `off` 仍可读取，但运行时统一归一化为 `conventional`，不能关闭格式校验。
- `commit.analyzeCount`：`PromptLanguage Auto` 分析的最近非合并提交数量，必须为正数。
- `commit.minimumSamples`：确认历史描述语言所需的最少样本，必须为正数且不大于 `analyzeCount`。
- `commit.confidenceThreshold`：历史描述语言的最高占比阈值，范围为 `(0, 1]`。
- `commit.fallback`：兼容字段，固定为 `conventional`。
- `version.read.pattern`：必须包含命名捕获组 `(?<version>...)`。
- `version.updates`：每项在升级版本时执行；`expectedMatches` 必须与实际匹配数完全一致。
- `prepare.parallel`：为 `true` 时并行执行所选构建命令，并在首个失败后终止兄弟进程。
- `prepare.bootstrapInputs`：依赖安装缓存输入，通常是项目清单和锁文件。
- `prepare.bootstrapRequiredPaths`：缓存有效时必须仍存在的依赖目录或状态文件；缺失时重新执行依赖准备。
- `prepare.bootstrapCommands`：仅在缓存输入或命令变化时执行的依赖准备步骤；状态保存在 `.git/auto-release/bootstrap.json`。
- `prepare.localCommands`：`LocalBuild` 使用的快速命令；缺失时回退到 `prepare.commands`。
- `prepare.commands`：正式 `Prepare` 使用的完整测试和打包命令；Windows 下通过 `cmd.exe` 执行。
- `prepare.localArtifacts`：本地快速构建的产物定义；缺失时回退到 `prepare.artifacts`，空数组表示构建后在受限目录中发现本地产物。
- `prepare.localSearchRoots`：本地产物发现根目录，用于 Electron 自定义输出目录和子目录中的 .NET 项目。
- `prepare.localOutputDirectory`：可选，默认 `output`；路径禁止 `{version}`、`{tag}`，`LocalBuild` 和草稿式正式发布都在此目录生成不含版本号的本地程序。
- `prepare.artifacts`：可为空；`destination` 只控制正式发布整理路径，`localName` 可选且只控制统一的本地产物文件名。
- `publish.workflow`：可省略；存在时按标签和 `HEAD` SHA 等待对应 GitHub Actions 工作流。

`publish.release.mode` 支持：

- `publish-draft`：工作流先创建草稿 Release；脚本校验必需资产、大小和 GitHub SHA256，下载复核后才公开。
- `create`：脚本在工作流成功后先创建草稿 Release；用 `uploadAssets` 列出文件或通配符，远端大小和 SHA256 必须与本地文件一致，下载复核后才公开。
- `none`：只推送分支和标签，不创建 GitHub Release。

`Publish` 可在同版本标签已存在时续跑，但本地与远端标签必须解析到当前 `HEAD`；任何标签冲突都会停止。已公开的同版本 Release 只做资产完整性复核，不再编辑。

字符串字段支持 `{projectName}`、`{version}` 和 `{tag}` 占位符。`version.updates[].replacement` 同时支持 .NET 正则替换引用，例如 `${1}` 和 `$2`。

## 自动生成的项目策略

### Tauri

- 从 `src-tauri/tauri.conf.json` 读取版本。
- 更新存在的 Tauri、`package.json`、`package-lock.json`、`Cargo.toml` 和可识别的 `Cargo.lock` 版本项。
- 工作流构建 Windows x64/ARM64、macOS Intel/Apple Silicon 和 Linux 安装包。
- 本地构建使用 `tauri build --no-bundle`，避免每次生成安装器；正式构建仍生成全部安装包。
- 使用 `tauri-apps/tauri-action` 创建草稿 Release，并校验 Windows 安装器、两个 DMG 和 Linux 包。

### Node.js

- 从 `package.json` 读取版本，并更新 `package.json` 与 `package-lock.json` 的根项目版本项。
- 按锁文件选择 npm、pnpm、Yarn 或 Bun，仅在清单声明时运行 test/build 脚本。
- 使用 `npm pack` 生成 `.tgz`，上传产物并创建草稿 Release。

### Go

- 从 `go.mod` 读取模块名；优先构建 `./cmd/<项目名>`，否则构建当前包。
- 使用已有 `VERSION`；缺失时从最新稳定 `vX.Y.Z` 标签推断，仍无标签则创建 `0.1.0`。
- 本地执行 `go test ./...` 和 Windows 构建；工作流生成 Windows、Linux、macOS 的 amd64/arm64 六个产物。

### Python

- 从 `pyproject.toml` 读取静态 PEP 621 或 Poetry 名称与版本。
- 识别 pip、uv 或 Poetry；本地快速构建只生成 wheel，正式构建生成 wheel 和 sdist。

### Rust

- 从根目录 `Cargo.toml` 的 `[package]` 读取名称与版本；仅工作区项目需手动配置。
- 本地运行 `cargo test --all` 和 `cargo build --release`；正式构建执行 `cargo package` 并发布 `.crate`。

### .NET

- 自动处理仅含一个 `.csproj`、`.fsproj` 或 `.vbproj` 的仓库。
- 使用 `<Version>`/`<VersionPrefix>`；缺失时创建 `VERSION`。本地执行 restore、test 和 build，正式构建执行 pack 并发布 `.nupkg`。

### Java

- 支持根目录 Maven `pom.xml` 或 Gradle `build.gradle(.kts)` 的静态语义版本。
- 优先使用 Maven/Gradle Wrapper，运行测试与构建后发布 `.jar`。

### CMake

- 从 `CMakeLists.txt` 读取 `project()` 和唯一的 `add_executable()` 目标。
- 构建 Windows、Linux、macOS 的 x64/ARM64 六个平台压缩包。

### Flutter

- 从 `pubspec.yaml` 读取名称与版本。
- 生成 APK、AAB、Windows、Linux、macOS Intel/Apple Silicon 和 Web 包。

### Android

- 识别唯一的 `com.android.application` 模块及 Gradle Wrapper。
- 更新静态 `versionName`，构建未签名 APK 和 AAB；签名配置继续由项目管理。

### Electron

- 从 Electron 依赖和 package scripts 识别桌面项目。
- 本地使用当前平台的项目构建脚本和自定义输出目录；正式工作流将六个平台输出整理为确定名称的压缩包。

### Docker

- Dockerfile 作为唯一主清单时自动识别；混合项目可显式指定 `-ProjectType docker`。
- 构建并推送 `linux/amd64`、`linux/arm64` GHCR 镜像，发布带 digest 的文本清单。

## 托管工作流保护

自动生成的工作流具备：

- `concurrency`：同一标签只允许一条发布链执行，且不自动取消已开始的发布。
- `timeout-minutes`：构建和发布任务分别限制最长运行时间。
- `permissions`：工作流默认只读，仅创建 Release 或推送容器的任务获取写权限。
- `retention-days`：中间产物默认只保留一天。
- Action 固定：所有 `uses:` 使用 40 位 commit SHA，同行注释记录对应主版本。

`-WhatIf` 返回计划但不生成配置、不更新版本、不运行构建、不暂存、不提交、不打标签、不推送。`-OutputFormat Json` 成功时返回操作、状态、复用状态、产物或提交信息；失败时返回稳定 `errorCode` 和停止阶段。

## 最小无工作流示例

```json
{
  "schemaVersion": 1,
  "projectName": "my-cli",
  "branch": "main",
  "remote": "origin",
  "tagPrefix": "v",
  "version": {
    "read": {
      "path": "package.json",
      "pattern": "\\\"version\\\"\\s*:\\s*\\\"(?<version>\\d+\\.\\d+\\.\\d+)\\\""
    },
    "updates": []
  },
  "prepare": {
    "parallel": false,
    "commands": [{ "name": "Check", "command": "npm test" }],
    "artifacts": []
  },
  "publish": {
    "release": {
      "mode": "create",
      "title": "{projectName} {tag}",
      "uploadAssets": ["dist/*"]
    }
  }
}
```
