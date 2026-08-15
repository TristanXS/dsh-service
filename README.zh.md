# DSH Service

[English](README.md) | 简体中文

[![CI](https://github.com/TristanXS/dsh-service/actions/workflows/ci.yml/badge.svg)](https://github.com/TristanXS/dsh-service/actions/workflows/ci.yml) [![许可证](https://img.shields.io/github/license/TristanXS/dsh-service)](LICENSE)

DSH Service 将 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) 作为可靠的用户级服务运行在 macOS（launchd）和 Linux（systemd）上：支持登录时启动、健康感知的生命周期命令、事务式更新与自动回滚。

> [!WARNING]
> DSH Service 目前为公开 Alpha 版本。它已经通过自动化测试与受控的 macOS `launchd` 真实冒烟测试，但命令、安装路径和行为在 `v1.0` 之前仍可能变化。

> [!CAUTION]
> DeepSeek Harness 目前处于开发者预览阶段，可能出现破坏兼容性的变更。

> [!NOTE]
> DSH Service 是独立的社区项目，与 DeepSeek AI 不存在隶属、背书、赞助或官方支持关系。DeepSeek、DeepSeek Harness 及相关商标归各自权利人所有。

## 为什么使用 DSH Service

DSH Service 让官方 DSH Web UI 在登录后持续可用，无需保持终端前台进程运行。

| 前台 `npx` | 托管服务 |
| --- | --- |
| 在当前终端中运行 | 作为一个用户级 LaunchAgent（macOS）或 systemd user unit（Linux）运行 |
| 前台进程退出时停止 | 登录时启动，并在意外退出后重启 |
| 没有托管状态或恢复能力 | 为生命周期命令和更新执行健康检查 |
| 需要手动调用软件包 | 安装带版本的发布并回滚失败的激活 |

## 要求

请在交互式登录会话中安装，两个平台都需满足以下前提条件：

- Node.js `^22.19.0 || >=24.0.0`
- 可在 `PATH` 中找到可执行的 `node` 与 `npm`
- 可访问 npm registry
- 本机有可用的传输控制协议（TCP）端口 `3080`

macOS 无需额外工具。Linux 还需要：

- systemd 且用户会话可用（`systemctl --user` 能连接到用户管理器）
- iproute2 提供的 `ss`（主流发行版标配）
- `xdg-open` 可选；缺失时 `dsh-service open` 会打印 URL 而不是打开浏览器

Windows 支持处于计划中，尚不可用。Homebrew 不是产品依赖；此仓库仅在持续集成（CI）运行器上用它安装 ShellCheck。

## 开始使用

克隆仓库，然后安装并打开本地界面：

```bash
git clone https://github.com/TristanXS/dsh-service.git
cd dsh-service
./install.sh
dsh-service status
dsh-service open
```

安装程序会获取当前的 `@deepseek-ai/dsh` 版本、启动服务并打开本地界面。若 `~/.local/bin` 不在 `PATH` 中，请使用安装后命令的绝对路径：

```bash
"$HOME/.local/bin/dsh-service" status
```

## 命令参考

此命令管理一个固定在 `http://127.0.0.1:3080` 地址上的用户级服务。

| 命令 | 操作 |
| --- | --- |
| `dsh-service install` | 安装或刷新管理器，安装最新 DSH 版本，启动服务并打开界面 |
| `dsh-service start` | 加载并启动服务 |
| `dsh-service stop` | 为当前登录会话卸载服务 |
| `dsh-service restart` | 重启服务，并等待替代进程变为健康状态 |
| `dsh-service status` | 输出管理器版本、DSH 版本、LaunchAgent 状态、进程 ID、URL 和健康状态 |
| `dsh-service open` | 仅在服务通过健康检查后打开界面 |
| `dsh-service logs` | 持续显示两个服务日志文件，直到你按下 `Control-C` |
| `dsh-service update` | 安装并激活最新 DSH 版本 |
| `dsh-service uninstall` | 移除管理器和服务，同时保留 `~/.dsh` |
| `dsh-service version` | 输出管理器版本 |
| `dsh-service help` | 输出命令帮助 |

LaunchAgent 在登录时启动，并通过 `KeepAlive` 在 DSH 意外退出后重启。`dsh-service stop` 会有意卸载任务，但保留其 plist。运行 `dsh-service start` 可立即恢复，或者 macOS 会在下次登录时加载它。运行 `dsh-service uninstall` 可移除登录启动。

在 Linux 上，相同语义对应一个名为 `dsh-service.service`、带 `Restart=on-failure` 的 systemd user unit。`dsh-service stop` 停止 unit 但保留 enabled 状态，下次登录时自动恢复；`dsh-service uninstall` 会禁用并移除它。

## 托管运行时

托管服务不运行 `npx`。安装和更新会将 `@deepseek-ai/dsh` 当前 npm `latest` 版本解析到私有的带版本软件包树中。管理器会记录 Node.js 可执行文件的绝对路径，并在 macOS 上通过 `launchd`、在 Linux 上通过 systemd 用户管理器调用 DSH 入口点。

相比之下，以下命令会在前台运行 DSH，并附着到你的终端：

```bash
npx @deepseek-ai/dsh@latest web --host 127.0.0.1 --port 3080
```

前台命令没有登录启动、管理器状态或托管回滚。`dsh-service` 占用端口 `3080` 时，请勿运行它。

## 更新与自动回滚

`dsh-service update` 只更新 DSH。它先解析 npm 的 `latest` 版本。如果当前版本已在该版本上验证，管理器会检查服务健康状态。健康的匹配不需要安装或重启，因此进程 ID 保持不变。

如果该版本已停止或不健康，管理器会按需启动或重启它，然后等待健康状态。端口 `3080` 上的外部监听器会阻止恢复。当前版本有效时，只有不同的 DSH 版本才会进入激活流程。

激活时，管理器会在变更发布链接前暂存并验证已解析的版本。它写入激活日志，将 `previous` 指向旧版本，将 `current` 指向候选版本，然后启动或重启服务。它会验证监听器归属和 Web 健康状态，再清除日志并清理未引用的版本。

从经审阅的检出副本更新管理器，然后再次运行安装程序：

```bash
git pull --ff-only
./install.sh
```

安装程序会以一个事务替换管理器命令和运行器。安装失败时，它会恢复之前的管理器文件。

如果 DSH 候选版本未通过健康检查，管理器会在删除候选版本前恢复并验证之前的版本。首次安装失败时，服务会停止并移除候选版本。如果回滚无法完成，管理器会保留恢复状态，而不会删除未经验证的版本。管理器保留当前和之前的版本，但不提供手动回滚命令。

## 安装路径

管理器拥有以下主目录中的路径。管理器根目录内包含运行器模板（`libexec/dsh-service-run`）、带版本的发布（`releases/release_id`，内含软件包树、`manifest.env`、`run` 与 `.complete` 标记）、`current` 与 `previous` 发布链接、激活日志（`activation.env`）、操作锁（`.lock`）和服务工作区（`workspace`）。

| 用途 | macOS | Linux |
| --- | --- | --- |
| 命令 | `~/.local/bin/dsh-service` | `~/.local/bin/dsh-service` |
| 管理器根目录 | `~/Library/Application Support/dsh-service` | `${XDG_DATA_HOME:-~/.local/share}/dsh-service` |
| 服务定义 | `~/Library/LaunchAgents/dev.dsh-service.web.plist` | `${XDG_CONFIG_HOME:-~/.config}/systemd/user/dsh-service.service` |
| 日志目录 | `~/Library/Logs/dsh-service` | `${XDG_STATE_HOME:-~/.local/state}/dsh-service` |
| 标准输出 | 日志目录下 `stdout.log` | 相同 |
| 标准错误 | 日志目录下 `stderr.log` | 相同 |

DSH 在 `~/.dsh` 中拥有用户状态；管理器不拥有该目录。`dsh-service uninstall` 会保留该目录及其全部内容。

## 排查服务问题

先运行状态命令。除非服务报告 `healthy`，否则它会以非零状态退出：

```bash
dsh-service status
```

使用日志检查启动和运行时错误：

```bash
dsh-service logs
```

如果状态显示 `unloaded`，请运行 `dsh-service start`。如果显示 `unhealthy` 或 `starting`，请在重启前检查两个日志。如果显示 `interrupted`，请运行 `dsh-service restart`，让管理器恢复已记录的激活。如果显示 `conflict`，请在变更服务前检查端口 `3080`。

其他进程占用端口 `3080` 时，管理器会拒绝启动或重启。请在不停止进程的情况下识别监听器——macOS：

```bash
/usr/sbin/lsof -nP -iTCP:3080 -sTCP:LISTEN
```

Linux：

```bash
ss -tlnp 'sport = :3080'
```

仅当你拥有该进程且打算释放端口时才停止它。托管服务始终绑定到 `127.0.0.1:3080`；此版本没有端口设置。

如果记录的 Node.js 可执行文件不再存在，请恢复受支持的 Node.js 版本，并从可信检出副本运行 `./install.sh`。新安装会记录当前 Node.js 的绝对路径。

## Linux 无头与服务器使用

systemd user unit 通常随最后一个登录会话结束而停止。对于常开机器（家庭服务器或 NAS），启用 lingering 让服务开机自启并在登出后持续运行：

```bash
loginctl enable-linger $USER
```

lingering 关闭时，`dsh-service install` 会打印提醒。服务仍然只绑定 `127.0.0.1:3080`；官方 DSH CLI 拒绝非回环绑定。远程访问请使用隧道而不是暴露端口：

```bash
ssh -L 3080:127.0.0.1:3080 your-server
```

然后在本地机器打开 `http://127.0.0.1:3080`。Tailscale 等转发到回环地址的 overlay 网络同理。

## 安全边界

DSH 可以使用你的用户权限执行代码和 shell 命令。请仅将它用于可信的项目和指令，并在授予敏感数据访问权限前审查命令。

安装和更新会从 npm 获取 `@deepseek-ai/dsh` 及其传递依赖。npm 可能以你的用户权限执行软件包生命周期脚本。安装前请审查软件包源、发布者和依赖风险。

该服务只监听互联网协议版本 4（IPv4）回环地址。回环绑定会限制网络暴露，但不会沙盒化 DSH，也不会验证本地客户端。任何可访问 `127.0.0.1:3080` 的本地进程都能连接服务。

## 已测试状态与兼容性限制

后端为 macOS 用户级 LaunchAgent 和 Linux systemd user unit。自动化 Bash 语法检查和隔离测试在 macOS 与 Ubuntu 上运行。macOS 受控真实冒烟测试在 macOS 26.5.2（build 25F84）、arm64 上以 DSH `0.1.0-rc.6` 完成。它验证了安装、状态、重启、同版本更新、停止、启动和卸载，也验证了移除全部管理器拥有的路径以及保留现有 `~/.dsh` 目录。

这些证据不构成通用兼容性保证。Alpha 版本之间不保证兼容；需要时会提供迁移或全新重装说明。

## 反馈与贡献

请通过 [GitHub Issues](https://github.com/TristanXS/dsh-service/issues) 报告可复现的缺陷。请附上操作系统及版本、架构、Node.js 版本、`dsh-service status` 和脱敏后的日志摘录。请勿公开 API 密钥或 `~/.dsh/.credentials.yaml` 的内容。

请通过 [GitHub Discussions](https://github.com/TristanXS/dsh-service/discussions) 提出问题、想法和未来 Windows 平台需求。贡献应保留以上安全和兼容性边界。

## 许可证

DSH Service 使用 [MIT License](LICENSE)。

## 仓库检查

贡献前请运行 CI 检查和空白字符检查：

```bash
/bin/bash -n bin/dsh-service libexec/dsh-service-run install.sh tests/*.sh
shellcheck -s bash bin/dsh-service libexec/dsh-service-run install.sh tests/*.sh
/bin/bash tests/run.sh
git diff --check
```
