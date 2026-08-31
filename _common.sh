# Docker tools for BuildBox - common functions
# Copyright (C) 2023-2026 Trusted Objects

# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# version 2, as published by the Free Software Foundation.

# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.

# You should have received a copy of the GNU General Public License
# along with this program; if not, see
# <https://www.gnu.org/licenses/>.

DOCKER_ENV_FILE=${BB_TARGET_BUILD_DIR}/docker.env
DOCKER_ENV_RESET_FILE=${BB_TARGET_BUILD_DIR}/docker.env.reset
DOCKER_ENV_LOCK=${BB_TARGET_BUILD_DIR}/docker.env.lock
# Kept across a re-sourcing of this file, which happens when a single process
# loads then unloads the tool
LOCK_OWNER="${LOCK_OWNER:-0}"

# Locks are handled by the BuildBox API rather than reimplemented here. It is
# already sourced when BuildBox loads the tool, but not when running from the
# tool executables (bin/docker_start, bin/docker_stop), hence this load.
if ! command -v bb_lock_try_acquire > /dev/null 2>&1; then
	# Tools scripts are disabled while loading the API: BuildBox loads the
	# tools when setting the local environment, which would source this very
	# file again
	BB_DISABLE_TOOLS_SCRIPTS=1
	source buildbox_utils.sh > /dev/null 2>&1
	unset BB_DISABLE_TOOLS_SCRIPTS
	if ! command -v bb_lock_try_acquire > /dev/null 2>&1; then
		echo "BuildBox API not found, unable to manage the Docker daemon lock"
	fi
fi

function reset_docker_env {
	if [ -f ${DOCKER_ENV_RESET_FILE} ]; then
		source ${DOCKER_ENV_RESET_FILE}
	fi
}

## Try to take the tool lock, without waiting.
## The BuildBox API holds it on a file descriptor, so the kernel releases it as
## soon as the holding process ends, even killed: no stale lock can be left
## behind to make every later load skip the Docker daemon management.
## Return 0 when the lock is taken, else 1
function lock_docker_env {
	bb_lock_try_acquire "${DOCKER_ENV_LOCK}"
	case $? in
		0)
			LOCK_OWNER=1
			return 0
			;;
		1)
			# Held by another instance, which is doing the job
			return 1
			;;
		*)
			echo "Unable to take the Docker daemon lock ${DOCKER_ENV_LOCK}"
			return 1
			;;
	esac
}

## Release the tool lock. The lock file is not removed: it only supports the
## lock, its presence does not mean the lock is held.
function unlock_docker_env {
	LOCK_OWNER=0
	bb_lock_release "${DOCKER_ENV_LOCK}"
}

function docker_tools_error_handler {
	if [ ${LOCK_OWNER} -ne 0 ]; then
		unlock_docker_env
	fi
}
trap 'docker_tools_error_handler' ERR
