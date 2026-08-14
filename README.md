# DSH Service

English | [简体中文](README.zh.md)

[![CI](https://github.com/TristanXS/dsh-service/actions/workflows/ci.yml/badge.svg)](https://github.com/TristanXS/dsh-service/actions/workflows/ci.yml) [![License](https://img.shields.io/github/license/TristanXS/dsh-service)](LICENSE)

DSH Service runs [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) as a reliable per-user macOS service with login startup, health-aware lifecycle commands, transactional updates, and automatic rollback.

> [!WARNING]
> DSH Service is a public alpha. Automated tests and a guarded macOS `launchd` smoke test passed, but commands, installed paths, and behavior may change before `v1.0`.

> [!CAUTION]
> DeepSeek Harness is in developer preview and may introduce compatibility-breaking changes.

> [!NOTE]
> DSH Service is an independent community project with no affiliation, endorsement, sponsorship, or official support from DeepSeek AI. DeepSeek, DeepSeek Harness, and related trademarks belong to their respective owners.

## Why use DSH Service

DSH Service keeps the official DSH Web UI available after login without leaving a terminal process running.

| Foreground `npx` | Managed service |
| --- | --- |
| Runs in the current terminal | Runs as one per-user macOS LaunchAgent |
| Stops when its foreground process exits | Starts at login and restarts after an unexpected exit |
| Has no managed status or recovery | Checks health for lifecycle commands and updates |
| Requires manual package invocation | Installs versioned releases and rolls back failed activation |

## Requirements

Install from an interactive macOS login with these prerequisites:

- Node.js `^22.19.0 || >=24.0.0`
- `node` and `npm` available as executable files on `PATH`
- Network access to the npm registry
- Transmission Control Protocol (TCP) port `3080` available on the local machine

DSH Service currently supports only macOS. Linux and Windows support is planned, not available. Homebrew is not a product dependency; this repository uses it only to install ShellCheck on the continuous integration (CI) runner.

## Get started

Clone the repository, then install and open the local interface:

```bash
git clone https://github.com/TristanXS/dsh-service.git
cd dsh-service
./install.sh
dsh-service status
dsh-service open
```

The installer fetches the current `@deepseek-ai/dsh` release, starts the service, and opens the local interface. If `~/.local/bin` is not on `PATH`, call the installed command by its absolute path:

```bash
"$HOME/.local/bin/dsh-service" status
```

## Command reference

The command controls one per-user service at the fixed address `http://127.0.0.1:3080`.

| Command | Action |
| --- | --- |
| `dsh-service install` | Install or refresh the manager, install the latest DSH release, start it, and open the interface |
| `dsh-service start` | Load and start the service |
| `dsh-service stop` | Unload the service for the current login session |
| `dsh-service restart` | Restart the service and wait for a healthy replacement process |
| `dsh-service status` | Print manager version, DSH version, LaunchAgent state, process ID, URL, and health |
| `dsh-service open` | Open the interface only after the service passes its health check |
| `dsh-service logs` | Follow both service log files until you press `Control-C` |
| `dsh-service update` | Install and activate the latest DSH release |
| `dsh-service uninstall` | Remove the manager and service while preserving `~/.dsh` |
| `dsh-service version` | Print the manager version |
| `dsh-service help` | Print command help |

The LaunchAgent starts at login and uses `KeepAlive` to restart DSH after an unexpected exit. `dsh-service stop` intentionally unloads the job but leaves its plist in place. Run `dsh-service start` to restore it now, or macOS loads it at your next login. Run `dsh-service uninstall` to remove login startup.

## Managed runtime

The managed service does not run `npx`. Install and update resolve the current npm `latest` version of `@deepseek-ai/dsh` into a private, versioned package tree. The manager records the absolute Node.js executable and invokes the DSH entry point through `launchd`.

By contrast, this command runs DSH in the foreground and attaches it to your terminal:

```bash
npx @deepseek-ai/dsh@latest web --host 127.0.0.1 --port 3080
```

The foreground command has no login startup, manager status, or managed rollback. Do not run it while `dsh-service` owns port `3080`.

## Updates and automatic rollback

`dsh-service update` updates DSH only. It resolves the npm `latest` version first. If the current release validates at that version, the manager checks service health. A healthy match needs no installation or restart, so its process ID remains unchanged.

If that release is stopped or unhealthy, the manager starts or restarts it as needed, then waits for health. A foreign listener on port `3080` blocks recovery. With a valid current release, only a different DSH version takes the activation path.

For activation, the manager stages and validates the resolved version before changing release links. It writes an activation journal, points `previous` to the old release, points `current` to the candidate, then starts or restarts the service. It verifies listener ownership and web health before clearing the journal and pruning unreferenced releases.

Update the manager from a reviewed checkout, then run the installer again:

```bash
git pull --ff-only
./install.sh
```

The installer replaces the manager command and runner as one transaction. It restores the prior manager files if the install fails.

If a DSH candidate fails its health check, the manager restores and verifies the previous release before deleting the candidate. A failed first install stops the service and removes its candidate. If rollback cannot finish, the manager preserves the recovery state instead of deleting an unverified release. The manager retains the current and previous releases, but it does not expose a manual rollback command.

## Installed paths

The manager owns these paths under your home directory. In the table, `release_id` represents a generated versioned directory name.

| Purpose | Path |
| --- | --- |
| Command | `~/.local/bin/dsh-service` |
| Manager root | `~/Library/Application Support/dsh-service` |
| Runner template | `~/Library/Application Support/dsh-service/libexec/dsh-service-run` |
| Versioned releases | `~/Library/Application Support/dsh-service/releases` |
| Release directory | `~/Library/Application Support/dsh-service/releases/release_id` |
| Release package tree | `~/Library/Application Support/dsh-service/releases/release_id/node_modules/` |
| Release manifest | `~/Library/Application Support/dsh-service/releases/release_id/manifest.env` |
| Release runner | `~/Library/Application Support/dsh-service/releases/release_id/run` |
| Release completion marker | `~/Library/Application Support/dsh-service/releases/release_id/.complete` |
| Active release link | `~/Library/Application Support/dsh-service/current` |
| Previous release link | `~/Library/Application Support/dsh-service/previous` |
| Activation journal | `~/Library/Application Support/dsh-service/activation.env` |
| Operation lock | `~/Library/Application Support/dsh-service/.lock` |
| Service workspace | `~/Library/Application Support/dsh-service/workspace` |
| LaunchAgent plist | `~/Library/LaunchAgents/dev.dsh-service.web.plist` |
| Log directory | `~/Library/Logs/dsh-service` |
| Standard output | `~/Library/Logs/dsh-service/stdout.log` |
| Standard error | `~/Library/Logs/dsh-service/stderr.log` |

DSH owns its user state in `~/.dsh`; the manager does not. `dsh-service uninstall` preserves that directory and all of its contents.

## Troubleshoot the service

Start with the status command. It exits with a nonzero status unless the service reports `healthy`:

```bash
dsh-service status
```

Use the logs to inspect startup and runtime errors:

```bash
dsh-service logs
```

If status reports `unloaded`, run `dsh-service start`. If it reports `unhealthy` or `starting`, inspect both logs before restarting. If it reports `interrupted`, run `dsh-service restart` so the manager can recover the recorded activation. If it reports `conflict`, inspect port `3080` before any service change.

The manager refuses to start or restart when another process owns port `3080`. Identify the listener without stopping it:

```bash
/usr/sbin/lsof -nP -iTCP:3080 -sTCP:LISTEN
```

Stop that process only if you own it and intend to release the port. The managed service always binds to `127.0.0.1:3080`; this release has no port setting.

If the recorded Node.js executable no longer exists, restore a supported Node.js version and run `./install.sh` from a trusted checkout. The new install records the current absolute Node.js path.

## Security boundary

DSH can execute code and shell commands with your macOS user permissions. Use it only with trusted projects and instructions, and review commands before granting access to sensitive data.

Install and update fetch `@deepseek-ai/dsh` and its transitive dependencies from npm. npm may execute package lifecycle scripts with your user permissions. Review the package source, publisher, and dependency risk before installation.

The service listens only on the Internet Protocol version 4 (IPv4) loopback address. Loopback binding limits network exposure, but it does not sandbox DSH or authenticate local clients. Any local process that can reach `127.0.0.1:3080` can contact the service.

## Tested status and compatibility limits

The only current backend is a per-user macOS LaunchAgent. Automated Bash syntax checks and isolated tests ran on macOS 26.5.2 (build 25F84), arm64. The guarded live smoke completed on that host with DSH `0.1.0-rc.6`. It verified install, status, restart, same-version update, stop, start, and uninstall. It also verified removal of every manager-owned path and preservation of the existing `~/.dsh` directory.

This evidence is not a general compatibility guarantee. Compatibility across alpha releases is not guaranteed. Migration or clean-reinstall instructions will be documented when required.

## Feedback and contributions

Use [GitHub Issues](https://github.com/TristanXS/dsh-service/issues) for reproducible bugs. Include your macOS version, architecture, Node.js version, `dsh-service status`, and redacted log excerpts. Do not publish API keys or the contents of `~/.dsh/.credentials.yaml`.

Use [GitHub Discussions](https://github.com/TristanXS/dsh-service/discussions) for questions, ideas, and future Linux or Windows platform requests. Contributions should preserve the security and compatibility boundaries described above.

## License

DSH Service is available under the [MIT License](LICENSE).

## Repository checks

Run the CI checks and a whitespace check before you contribute:

```bash
/bin/bash -n bin/dsh-service libexec/dsh-service-run install.sh tests/*.sh
shellcheck -s bash bin/dsh-service libexec/dsh-service-run install.sh tests/*.sh
/bin/bash tests/run.sh
git diff --check
```
