# BuildBox Docker tools

A [BuildBox](https://github.com/TrustedObjects/BuildBox) tool that manages a Docker daemon in a BuildBox target environment.

## Purpose

When listed as a tool in a BuildBox target, this tool initializes a Docker daemon specifically for this target on load and tears it down cleanly on unload. Any package build script running within that target can then use Docker features.

## Installation

In your `.bbx/packages`, add a `buildbox_docker_tools` package file with this content:

```bash
SRC_PROTO=git
SRC_URI=https://github.com/TrustedObjects/BuildBox-docker-tools.git
SRC_REVISION="master"
SRC_BUILD=prebuilt
```

## Usage

Assuming you have in your BuildBox target file a `TOOLS=tools.<TARGET>` entry, you can list the tool in your target's tools file (`.bbx/tools.<TARGET>`):

```
buildbox_docker_tools
```

or, to use a given release:

```
buildbox_docker_tools-1.0.15
```

BuildBox will source `load.sh` when the tool is loaded and `unload.sh` when it is unloaded.

## Configuration

Set these variables in your target file (`.bbx/target.<NAME>`) before the tool is loaded:

| Variable | Default | Description |
|---|---|---|
| `BB_TARGET_VAR_DOCKER_ROOTLESS` | `0` | Set to `1` to run the daemon via `dockerd-rootless.sh` instead of `sudo dockerd` |
| `BB_TARGET_VAR_DOCKER_CONFIG_FILE` | _(none)_ | Absolute path to a custom `daemon.json`; symlinked in place of the generated empty config |

## Behavior

On load, `load.sh`:

1. Generates and exports all Docker environment variables (paths rooted at `$BB_TARGET_BUILD_DIR`) and writes them to `$BB_TARGET_BUILD_DIR/docker.env` so concurrent callers can reuse them without regenerating.
2. Acquires an atomic lock via `mkdir $BB_TARGET_BUILD_DIR/docker.env.lock`. If another instance already holds the lock, this instance sources the existing environment and returns immediately.
3. Skips startup if a `dockerd` process matching the stored PID is already running.
4. Creates all required directories (`etc/docker`, `var/lib/docker`, `var/log`, `$DOCKER_EXEC_ROOT`). If `BB_TARGET_VAR_DOCKER_CONFIG_FILE` is set, symlinks that file as `daemon.json`; otherwise writes an empty `{}`.
5. Launches `dockerd` (or `dockerd-rootless.sh`) in a subshell, redirecting output to `$DOCKER_LOGS_FILE`.
6. Waits for `$DOCKER_PID_FILE` to appear using `inotifywait`, then releases the lock.

On unload, `unload.sh`:

1. Acquires the same lock. If another instance holds it, resets the Docker environment variables and returns.
2. Sources `$BB_TARGET_BUILD_DIR/docker.env` to recover all paths.
3. Sends SIGTERM to the daemon and waits for `$DOCKER_PID_FILE` to be deleted (up to 30 s total).
4. Unmounts `$DOCKER_DATA_ROOT` if it is a mount point (root mode only).
5. Uses `setfacl` to grant the `buildbox` user `rwX` access to all Docker-created directories, and removes sticky bits with `chmod o-t` so the directories can be deleted.
6. Removes `$DOCKER_EXEC_ROOT` and unsets all Docker environment variables, then releases the lock.

## License

Copyright Trusted Objects.

GNU General Public License v2. See [LICENSE](LICENSE) for details.
