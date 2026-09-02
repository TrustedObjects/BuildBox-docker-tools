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

## Check the container image can run a Docker daemon.
## A derived image carries any name, so the image reference proves nothing:
## what is tested is the set of commands this tool actually runs, which differs
## between root and rootless mode.
## Prints what is missing and how to fix it when the image is not usable.
## @return 0 when the image is usable, else 1
function docker_tools_check_image {
	local required
	if [ "${BB_TARGET_VAR_DOCKER_ROOTLESS}" = "1" ]; then
		required=(dockerd-rootless.sh rootlesskit-docker-proxy inotifywait setfacl)
	else
		required=(dockerd docker-proxy ip inotifywait setfacl)
	fi

	local missing=""
	local cmd
	# Quoted expansion: an unquoted one does not split into words in ZSH
	for cmd in "${required[@]}"; do
		if ! command -v "${cmd}" > /dev/null 2>&1; then
			missing="${missing} ${cmd}"
		fi
	done
	if [ -z "${missing}" ]; then
		return 0
	fi

	echo "Error: the container image of this project can not run a Docker daemon."
	echo "       Missing:${missing}"
	echo "       Declare the 'buildbox-docker' image, or an image derived from it,"
	echo "       in the project '.bbx/image' file:"
	echo "         trustedobjects/buildbox-docker:<VERSION>"
	echo "       Docker daemon of target ${BB_TARGET} not started."
	return 1
}

function reset_docker_env {
	if [ -f ${DOCKER_ENV_RESET_FILE} ]; then
		source ${DOCKER_ENV_RESET_FILE}
	fi
}

## Try to take the tool lock, without waiting.
## The BuildBox API makes it a symbolic link whose target is the PID of the
## owner: a lock whose owner is gone is stale and taken over by the next
## instance, even if that owner was killed, so no stale lock can be left behind
## to make every later load skip the Docker daemon management.
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
