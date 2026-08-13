# Unofficial macOS service manager for DeepSeek Harness

`dsh-mac` installs DeepSeek Harness (DSH) as a per-user macOS LaunchAgent on `http://127.0.0.1:3080`. It manages start, stop, update, logs, and removal without a global npm install.

## Meet the requirements

Install from an interactive macOS login with these prerequisites:

- Node.js `^22.19.0 || >=24.0.0`
- `node` and `npm` available as executable files on `PATH`
- Network access to the npm registry
- Transmission Control Protocol (TCP) port `3080` available on the local machine

Homebrew is not a product dependency. This repository uses it only to install ShellCheck on the continuous integration (CI) runner.

## Install the service

Run the installer from a trusted checkout:

```bash
./install.sh
```

The installer fetches the current `@deepseek-ai/dsh` release, starts the service, and opens the local interface. If `~/.local/bin` is not on `PATH`, call the installed command by its absolute path:

```bash
"$HOME/.local/bin/dsh-mac" status
```

## Manage the service

The command controls one per-user service at the fixed address `http://127.0.0.1:3080`.

| Command | Action |
| --- | --- |
| `dsh-mac install` | Install or refresh the manager, install the latest DSH release, start it, and open the interface |
| `dsh-mac start` | Load and start the service |
| `dsh-mac stop` | Unload the service for the current login session |
| `dsh-mac restart` | Restart the service and wait for a healthy replacement process |
| `dsh-mac status` | Print manager version, DSH version, LaunchAgent state, process ID, URL, and health |
| `dsh-mac open` | Open the interface only after the service passes its health check |
| `dsh-mac logs` | Follow both service log files until you press `Control-C` |
| `dsh-mac update` | Install and activate the latest DSH release |
| `dsh-mac uninstall` | Remove the manager and service while preserving `~/.dsh` |
| `dsh-mac version` | Print the manager version |
| `dsh-mac help` | Print command help |

The LaunchAgent starts at login and uses `KeepAlive` to restart DSH after an unexpected exit. `dsh-mac stop` intentionally unloads the job but leaves its plist in place. Run `dsh-mac start` to restore it now, or macOS will load it at your next login. Run `dsh-mac uninstall` to remove login autostart.

## Understand the managed runtime

The managed service does not run `npx`. It installs an exact DSH version in a private, versioned package tree. It records the absolute Node.js executable and invokes the DSH entry point through `launchd`.

By contrast, this command runs DSH in the foreground and attaches it to your terminal:

```bash
npx @deepseek-ai/dsh@latest web --host 127.0.0.1 --port 3080
```

The foreground command has no login autostart, manager status, or managed rollback. Do not run it while `dsh-mac` owns port `3080`.

## Update DSH and the manager

`dsh-mac update` updates DSH only. It first resolves the npm `latest` version. If the current release validates at that version, the manager checks service health. A healthy match needs no installation or restart, so its process ID remains unchanged.

If that release is stopped or unhealthy, the manager starts or restarts it as needed, then waits for health. A foreign listener on port `3080` blocks recovery. With a valid current release, only a different DSH version takes the activation path.

For activation, the manager stages and validates the resolved version before changing release links. It writes an activation journal and points `previous` to the old release. It points `current` to the candidate, then starts or restarts the service. It verifies listener ownership and web health before clearing the journal and pruning unreferenced releases.

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
| Command | `~/.local/bin/dsh-mac` |
| Manager root | `~/Library/Application Support/dsh-mac` |
| Runner template | `~/Library/Application Support/dsh-mac/libexec/dsh-mac-run` |
| Versioned releases | `~/Library/Application Support/dsh-mac/releases` |
| Release directory | `~/Library/Application Support/dsh-mac/releases/release_id` |
| Release package tree | `~/Library/Application Support/dsh-mac/releases/release_id/node_modules/` |
| Release manifest | `~/Library/Application Support/dsh-mac/releases/release_id/manifest.env` |
| Release runner | `~/Library/Application Support/dsh-mac/releases/release_id/run` |
| Release completion marker | `~/Library/Application Support/dsh-mac/releases/release_id/.complete` |
| Active release link | `~/Library/Application Support/dsh-mac/current` |
| Previous release link | `~/Library/Application Support/dsh-mac/previous` |
| Activation journal | `~/Library/Application Support/dsh-mac/activation.env` |
| Operation lock | `~/Library/Application Support/dsh-mac/.lock` |
| Service workspace | `~/Library/Application Support/dsh-mac/workspace` |
| LaunchAgent plist | `~/Library/LaunchAgents/dev.dsh-mac.web.plist` |
| Log directory | `~/Library/Logs/dsh-mac` |
| Standard output | `~/Library/Logs/dsh-mac/stdout.log` |
| Standard error | `~/Library/Logs/dsh-mac/stderr.log` |

DSH owns its user state in `~/.dsh`; the manager does not. `dsh-mac uninstall` preserves that directory and all of its contents.

## Troubleshoot the service

Start with the status command. It exits with a nonzero status unless the service reports `healthy`:

```bash
dsh-mac status
```

Use the logs to inspect startup and runtime errors:

```bash
dsh-mac logs
```

If status reports `unloaded`, run `dsh-mac start`. If it reports `unhealthy` or `starting`, inspect both logs before restarting. If it reports `interrupted`, rerun `dsh-mac restart` so the manager can recover the recorded activation. If it reports `conflict`, inspect port `3080` before any service change.

The manager refuses to start or restart when another process owns port `3080`. Identify the listener without stopping it:

```bash
/usr/sbin/lsof -nP -iTCP:3080 -sTCP:LISTEN
```

Stop that process only if you own it and intend to release the port. The managed service always binds to `127.0.0.1:3080`; this release has no port setting.

If the recorded Node.js executable no longer exists, restore a supported Node.js version and run `./install.sh` from a trusted checkout. The new install records the current absolute Node.js path.

## Review the security boundary

DSH can execute code and shell commands with your macOS user permissions. Use it only with trusted projects and instructions, and review commands before granting access to sensitive data.

Install and update operations fetch `@deepseek-ai/dsh` plus its transitive dependencies from npm. npm may execute package lifecycle scripts with your user permissions. Review the package source, publisher, and dependency risk before installation.

The service listens only on the Internet Protocol version 4 (IPv4) loopback address. Loopback binding limits network exposure, but it does not sandbox DSH or authenticate local clients. Any local process that can reach `127.0.0.1:3080` can contact the service.

## Project status and attribution

This project is an unofficial public alpha with no affiliation to DeepSeek. DeepSeek does not endorse or support it. DeepSeek, DeepSeek Harness, and related trademarks belong to their respective owners.

Automated Bash syntax checks and isolated tests ran on macOS 26.5.2 (build 25F84), arm64. The guarded live install smoke did not run because port `3080` already had a listener. This project does not claim a successful live smoke on that host.

## Run the repository checks

Contributors can run the CI checks plus a whitespace check:

```bash
/bin/bash -n bin/dsh-mac libexec/dsh-mac-run install.sh tests/*.sh
shellcheck -s bash bin/dsh-mac libexec/dsh-mac-run install.sh tests/*.sh
/bin/bash tests/run.sh
git diff --check
```
