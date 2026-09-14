# ChatGPT 额度仪表盘（macOS / Windows）

这是一个独立的桌面小工具，用仪表盘图标和文字直接显示 Codex 账户的两个限额窗口：

- 5 小时窗口剩余比例
- 7 天窗口剩余比例
- 两个窗口的预计重置倒计时
- 实时读取时间与数据来源标识

## Windows

Windows 版本保留 macOS 版本的额度读取、快照回退、详情弹窗和刷新菜单；macOS 菜单栏项目对应替换为 Windows 系统托盘 `NotifyIcon`。左键托盘图标显示/关闭详情，右键菜单可显示额度、立即刷新或退出；托盘悬停提示显示 5 小时与 7 天剩余比例。

安装后从开始菜单或桌面打开“ChatGPT额度仪表盘”。快捷方式直接运行 GUI 程序 `ChatGPTQuotaPet.exe`，在进程内部托管系统 PowerShell 引擎和 WinForms，不启动 PowerShell 终端进程，也不需要开着终端。启动后仅显示托盘图标，点击托盘图标时展开详情页。开发时也可以在 PowerShell 中执行：

```powershell
.\ChatGPTQuotaPet.ps1
```

Windows 版本使用系统自带的 PowerShell 5.1+ 和 WinForms，不需要安装 .NET SDK。启动前可运行核心逻辑自检：

```powershell
.\build-windows.ps1 -SelfTest
```

需要验证托盘和详情窗口初始化时，可运行：

```powershell
.\build-windows.ps1 -UiSelfTest
```

若要输出与 macOS `--probe` 相同格式的诊断结果：

```powershell
.\build-windows.ps1 -Probe
```

构建可安装的 Windows 程序：

```powershell
.\build-windows-installer.ps1
```

安装包会生成到 `Codex_OPT\ChatGPTQuotaPet-WindowsInstaller\ChatGPT额度仪表盘.exe`。双击这个 `.exe` 后会按当前用户安装，不需要管理员权限，并创建桌面、开始菜单快捷方式和卸载项；安装器只使用一次性的引导脚本，完成后立即退出，安装后的程序和快捷方式不通过 `cmd.exe` 启动，不需要再进入项目文件夹。

## macOS

macOS 详情页采用内容优先的布局：两行额度直接展示剩余比例、重置时间和消耗速率，底部保留实时／快照状态。macOS 26 及以上的刷新与关闭按钮使用原生 Liquid Glass，旧系统回退到标准按钮。支持系统深浅色、减少透明度和减少动态效果设置，⌘R 可刷新额度。

原有菜单栏项目和 Swift/AppKit 构建方式保持不变；可使用 `--show-details` 启动参数自动展开详情页。

## 启动

双击 `Start-ChatGPTQuotaPet.command`。首次运行会编译并打开 `ChatGPTQuotaPet.app`；之后也可以直接双击项目根目录中的 `ChatGPTQuotaPet.app`。

状态栏会直接显示两行剩余额度：上面是 `5h 76%`，下面是 `7d 76%`，左侧为仪表盘图标。点击状态栏项目后，会在状态栏下方展开额度详情；点击外部或按 Esc 可关闭弹窗，右键状态栏项目可立即刷新或退出。

如果系统阻止 `.command` 或 `.app`，请在“系统设置 → 隐私与安全性”中允许打开，或先在终端执行：

```zsh
chmod +x ./Start-ChatGPTQuotaPet.command ./macOS/build-mac.sh
```

## 编译与自检

```zsh
./macOS/build-mac.sh
./ChatGPTQuotaPet.app/Contents/MacOS/ChatGPTQuotaPet --probe
```

`build-mac.sh` 会按当前 Mac 的 CPU 架构编译，并以 macOS 13.0 为最低兼容版本。自检只输出剩余比例、采样时间和来源，不输出原始会话内容。

## 数据来源与限制

程序优先通过本机 Codex `app-server` 的 `account/rateLimits/read` 接口读取实时额度，不读取 `auth.json`，不保存访问令牌。若本地接口暂时不可用，会自动回退到 `~/.codex/sessions/` 中最近的 `rate_limits` 快照，并在弹窗底部标记为“快照”。

此版本显示的是 Codex/ChatGPT 账户中 Codex 相关的 5 小时与 7 天限额，不是 ChatGPT 普通对话、语音或图片额度的统一总余额；额度数据仍以官方使用情况页面为准：

<https://learn.chatgpt.com/docs/pricing>

如果仍显示“暂时没有可用快照”，请确认 Codex 已登录并在 ChatGPT/Codex 中运行一次任务，再重新启动工具。
