# BuildBox Docker tools

A [BuildBox](https://github.com/TrustedObjects/BuildBox) tool that manages a Docker daemon in a BuildBox target environment.

## Purpose

When listed as a tool in a BuildBox target, this tool initializes a Docker daemon specifically for this target on load and tears it down cleanly on unload. Any package build script running within that target can then use Docker features.

## Installation

### Container image

This tool starts a real Docker daemon inside the BuildBox container, so the
project image must ship a Docker installation. The BuildBox base image does
not: use the `buildbox-docker` variant, published on [Docker
Hub](https://hub.docker.com/repository/docker/trustedobjects/buildbox-docker),
or any image derived from it.

Declare it in the project `.bbx/image` file:

```
trustedobjects/buildbox-docker:2.0.0
```

or at project creation:

```
bbx init --image trustedobjects/buildbox-docker:2.0.0 my_project
```

A project needing more than Docker derives its own image from the variant:

```dockerfile
FROM trustedobjects/buildbox-docker:2.0.0
RUN apt-get install --yes my-extra-package
```

See [Docker variant
image](https://buildbox.trusted-objects.com/dev/container.html#docker-variant-image)
for building and tagging it from the BuildBox sources.

### Tool package

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
| `BB_TARGET_VAR_DOCKER_NETWORK_SLOT` | _(derived)_ | Network slot of the target, `0` to `31`. Set it only to resolve a collision, see [Network ranges](#network-ranges) |

## Behavior

On load, `load.sh`:

1. Generates and exports all Docker environment variables (paths rooted at `$BB_TARGET_BUILD_DIR`) and writes them to `$BB_TARGET_BUILD_DIR/docker.env` so concurrent callers can reuse them without regenerating.
2. Takes the tool lock on `$BB_TARGET_BUILD_DIR/docker.env.lock` through the [BuildBox API](https://buildbox.trusted-objects.com/dev/api.html#locks) (`bb_lock_try_acquire`), without waiting. If another instance already holds it, this instance sources the existing environment and returns immediately. Since BuildBox 2.1.0 the lock is a symbolic link whose target is the PID of the process holding it: no file descriptor is involved, so the daemon started here never inherits the lock, and a lock whose owner is gone is stale and taken over by the next instance, even if that owner was killed.
3. Skips startup if a `dockerd` process matching the stored PID is already running.
4. Creates all required directories (`etc/docker`, `var/lib/docker`, `var/log`, `$DOCKER_EXEC_ROOT`) and generates `daemon.json` from `BB_TARGET_VAR_DOCKER_CONFIG_FILE` (or `{}`), completed with the networks pool of the target when it defines none. The provided file is never modified, and the generated one is refreshed at each start.
5. In root mode, creates the bridge dedicated to the target and warns if its range is already routed (see [Network ranges](#network-ranges)).
6. Launches `dockerd` (or `dockerd-rootless.sh`) in a subshell, redirecting output to `$DOCKER_LOGS_FILE`.
7. Waits for `$DOCKER_PID_FILE` to appear using `inotifywait`, then releases the lock. After 60 s without daemon, gives up and prints the last lines of `$DOCKER_LOGS_FILE`.

On unload, `unload.sh`:

1. Acquires the same lock. If another instance holds it, resets the Docker environment variables and returns.
2. Sources `$BB_TARGET_BUILD_DIR/docker.env` to recover all paths.
3. Lists the bridges declared by the daemon and prunes the networks it no longer uses (root mode only).
4. Sends SIGTERM to the daemon and waits for `$DOCKER_PID_FILE` to be deleted (up to 30 s total).
5. Removes the bridges left behind, skipping any bridge which still has interfaces attached (root mode only).
6. Unmounts `$DOCKER_DATA_ROOT` if it is a mount point (root mode only).
7. Uses `setfacl` to grant the `buildbox` user `rwX` access to all Docker-created directories, and removes sticky bits with `chmod o-t` so the directories can be deleted.
8. Removes `$DOCKER_EXEC_ROOT` and unsets all Docker environment variables, then releases the lock.

## Network ranges

In root mode, the daemon runs in the BuildBox container network namespace, which
is the host one when BuildBox runs the container with `--network=host` (the
default). Its bridges, its subnets and its iptables rules are therefore created
next to those of the host Docker daemon, which does not know about them. Two
consequences:

- a subnet allocated by this daemon can be the one another daemon already uses,
  and a duplicate route silently black holes every container of the target: no
  DNS, no registry, no access to any service,
- a bridge left behind survives the BuildBox container, and keeps colliding
  afterwards.

To avoid both, each target gets a slot in `10.192.0.0/11`, a range outside the
default Docker ones (`172.17.0.0/12` and `192.168.0.0/16`):

| Resource | Value | Daemon option |
|---|---|---|
| Bridge name | `bbxdocker<SLOT>` | `--bridge` |
| Bridge subnet | `10.<192 + SLOT>.0.0/24` | address of the bridge |
| Networks pool | `10.<192 + SLOT>.128.0/17`, `/24` each | `default-address-pools` in `daemon.json` |

The networks pool goes into `daemon.json`, the only place the daemon accepts it.

The slot is derived from the target identity, so it is stable across daemon
restarts, which the daemon requires for its bridge. Two targets can end up on
the same slot: `load.sh` then warns that the range is already routed, and
`BB_TARGET_VAR_DOCKER_NETWORK_SLOT` allows to move one of them.

On unload, the networks of the daemon are pruned and the bridges it declared are
removed, so nothing is left in the host network namespace.

**Note:** a target whose Docker data root was created before this tool pinned the
bridge keeps the previous bridge recorded in `$DOCKER_DATA_ROOT/network`. Docker
reconciles it and moves the default network to the dedicated bridge (verified
with Docker 29). Should an older Docker refuse to start, wipe the data root with
`bbx target clean`, which removes `$BB_TARGET_BUILD_DIR`.

## License

Copyright Trusted Objects.

GNU General Public License v2. See [LICENSE](LICENSE) for details.
