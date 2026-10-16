# NeoShuttle

用 Swift 原生重写的 [Shuttle](https://github.com/fitztrev/shuttle) 菜单栏快捷命令工具。Apple Silicon 原生运行，不需要 Rosetta。内置 8 种终端适配，其余终端可通过 `custom_terminals` 自行接入。

## 安装

```sh
Scripts/build_dmg.sh
```

在 `dist/` 生成 `NeoShuttle-<版本>-development.dmg` 和对应的 `.sha256`。打开 DMG，把 NeoShuttle 拖到“应用程序”即可。这种包使用你本机的开发证书签名（没有配置时为临时签名），适合装在自己的 Mac 上。

要发给别人用，需要 Developer ID 签名并经过 Apple 公证：

```sh
RELEASE_MODE=developer-id NOTARY_KEYCHAIN_PROFILE=<notarytool 的钥匙串配置名> Scripts/build_dmg.sh
```

`dist/` 和 DMG 都不会提交到仓库。

## 配置

直接读取原来的 `~/.shuttle.json`。`~/.shuttle.path` 重定向、`~/.shuttle-alt.json` 追加、`~/.ssh/config` 合并（含 `Include` 和 `# shuttle.name`）、`[aaa]` 排序前缀、`[---]` 分隔线、`cmd` 为 URL 时直接打开，这些行为都与原版一致。每次打开菜单都会重新读取配置，改完不用重启；配置有问题时，菜单顶部会显示 ⚠️ 提示。文件不存在时会生成一份示例，已有文件不会被改写。

| 键 | 取值 | 说明 |
|---|---|---|
| `terminal` | 内置终端名，或 `custom_terminals` 里的名字 | 大小写和 `.app` 后缀都可以省略 |
| 条目内 `terminal` | 同上 | **新增**：单条覆盖全局终端 |
| `custom_terminals` | 见下文 | **新增**：接入没有内置适配的终端；同名时优先于内置适配 |
| `inTerminal` / `open_in` | `new` / `tab` / `current` / `split` | `split` 为新增；`open_in` 与原版一样只认 `new`、`tab` |
| `seedmux_command` | 命令 | 有值时优先于 `cmd`，兼容旧的 `shuttle-seedmux://` 转接配置 |
| `theme` / `default_theme` | 描述文件名 | Terminal 的“描述文件”或 iTerm 的 Profile |
| `title` | 文本 | 默认取菜单名；Terminal、iTerm、kitty、WezTerm、Alacritty、Warp 有效 |
| `editor` | `default` / 应用名或 bundle id / 终端编辑器命令 | “编辑配置…”用什么打开。`default` 跟随系统对 `.json` 的默认应用；`Cursor`、`Zed` 等直接用该应用打开；`vi`、`nano` 在终端里打开 |

## 设置窗口

菜单里的“设置…”（⌘,）打开图形界面，不用手改 JSON：

- **菜单条目**：左侧是和菜单一致的树（分组在前、按名称排序），右侧编辑名称、命令、终端、打开位置、主题、标题、所在分组、排序键和分隔线。右键可以运行、复制、移动、删除；“运行测试”会用尚未保存的设置执行一次。
- **通用**：默认终端和位置、默认主题、“编辑配置文件…”用的编辑器、是否合并 `~/.ssh/config` 及忽略规则、登录时启动。
- **自定义终端**：新建、改名（引用它的条目会一起改名）、切换启动模板或模拟按键，并可一键测试。

保存（⌘S）时写回 `~/.shuttle.json`，界面不认识的字段（如 `seedmux_id`）原样保留。每次打开窗口后的第一次保存前，会把原文件备份到 `~/.shuttle.json.bak`。文件会被重新排版，JSON5 的 `//` 注释不会保留。文件在别处被改过时会先询问；文件无法解析时不允许编辑，避免覆盖原文件。`~/.ssh/config` 里的主机和 `~/.shuttle-alt.json` 里的条目只读，不在窗口中编辑。

## 内置终端

| 终端 | 接口 | new | tab | current | split | 前提 |
|---|---|---|---|---|---|---|
| Terminal | AppleScript | 新窗口 | ⌘T 后执行 | 前台标签 | 同 tab | 自动化；tab 需辅助功能（没有时退回新窗口） |
| iTerm | AppleScript | 新窗口 | 新标签 | 当前会话 | 垂直分屏 | 自动化 |
| Ghostty 1.3+ | AppleScript | 新窗口 | 新标签 | 当前终端 | 向右分屏 | 自动化 |
| Seedmux | 本地桥 + ⌘T | 新页签 | 新页签 | 聚焦面板 | `/spawn` 分屏 | new/tab 需辅助功能（没有时退回分屏） |
| Warp | 临时 Launch Configuration | 新窗口 | 新窗口 | 新窗口 | 新窗口 | 无 |
| kitty | `kitty @` 远程控制 | 新窗口 | 新标签 | 当前窗口 | 分屏 | kitty.conf 开 `allow_remote_control` 和 `listen_on`；否则每次开新窗口 |
| WezTerm | `wezterm cli` | 新窗口 | 新标签 | 当前面板 | 向右分屏 | WezTerm 未运行时开新窗口 |
| Alacritty | `alacritty msg` | 新窗口 | 新窗口 | 新窗口 | 新窗口 | Alacritty 本身没有标签和分屏 |

各终端的实现细节：

- Seedmux 没有 AppleScript 和 URL Scheme，走的是它的本地 TeamBridge（`~/Library/Application Support/Seedmux/team-bridge.json`）：先 ⌘T 新建页签，等 shell 出现提示符（会自动回答 oh-my-zsh 的更新询问），再发送命令。命令发出后不自动重试，避免重复登录。`current` 模式下，如果聚焦面板正在运行 agent，会改开新页签。
- Warp 只能通过 Launch Configuration 执行命令：每次在 `~/.warp/launch_configurations/` 写一个 `neoshuttle-*.yaml`，用 `warp://launch/<name>` 打开，15 秒后删除。Warp 未运行时会先启动它，再等 3 秒，因为它刚启动时会丢弃链接。
- kitty、WezTerm、Alacritty 以“登录交互 shell 执行命令，结束后留在 shell”的方式启动（`$SHELL -l -i -c 'cmd' ; exec $SHELL -l`），与 Terminal 里直接敲命令的体验一致。

## 自定义终端

```json
"custom_terminals": {
  "Rio":   { "launch": "open -na Rio --args -e /bin/zsh -lic {cmd}" },
  "Tabby": { "launch": "open -na Tabby --args run /bin/zsh -lic {cmd}" },
  "Hyper": { "app": "Hyper", "keystroke": true, "delay": 1.0 }
}
```

- `launch`：在登录 shell 里执行的命令行。`{cmd}`、`{title}` 会被替换成已加引号的单个参数，不要再给它们加引号。非零退出码会以弹窗报错。
- `keystroke`：给完全没有接口的终端兜底。做法是把 `app`（应用名或 bundle id）切到前台，`new` 按 ⌘N，`tab`/`split` 按 ⌘T，`current` 不按，等待 `delay` 秒（默认 0.8）后输入命令并回车。输入用 Unicode 按键事件，不占用剪贴板，也不受输入法影响；需要辅助功能权限。如果等待期间焦点被切走，会放弃发送。

## 构建

需要 Xcode 和 [XcodeGen](https://github.com/yonaskolb/XcodeGen)（`brew install xcodegen`）。工程文件由 XcodeGen 生成，不在仓库里。

签名：默认是本地临时签名（ad-hoc），可以直接构建运行。想用自己的开发者证书，把 `Config/Signing.local.xcconfig.example` 复制成 `Config/Signing.local.xcconfig` 并填入 Team ID 和 Bundle ID 前缀；这个文件不会被提交。用固定证书签名的好处是，重新编译后 macOS 不会再次要求“自动化”和“辅助功能”授权。

```sh
xcodegen generate
xcodebuild -project NeoShuttle.xcodeproj -scheme NeoShuttle test          # 单元测试
xcodebuild -project NeoShuttle.xcodeproj -scheme NeoShuttle -configuration Release -derivedDataPath build/DerivedData build
```

Debug 版可以不点菜单直接测试：`--debug-open-settings` 打开设置窗口，`NEOSHUTTLE_CONFIG=<路径>` 环境变量改用另一份配置文件；测试某个启动器：`open -n NeoShuttle.app --args --debug-launch <终端名 | custom:<模板>> <mode> "<命令>"`。

`NeoShuttleCore` 是纯逻辑（配置解析、ssh_config、提示符识别、各种转义与模板），有单元测试；`NeoShuttle` 负责菜单栏和各终端的启动器。
