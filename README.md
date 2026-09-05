# ChatGPT 额度仪表盘（macOS）

这是一个独立的 macOS 菜单栏小工具，用仪表盘图标和文字直接显示 Codex 账户的两个限额窗口：

- 5 小时窗口剩余比例
- 7 天窗口剩余比例
- 两个窗口的预计重置倒计时
- 实时读取时间与数据来源标识

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
