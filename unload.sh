# Docker tools for BuildBox - unload script
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

tool_dir="$( cd "$( dirname "${BASH_SOURCE[0]:-$0}" )" && pwd )"
source ${tool_dir}/_common.sh

if ! lock_docker_env; then
	# Docker daemon stop already handled by another instance: nothing to do
	reset_docker_env
	return
fi

# Load environment
if [ -f ${DOCKER_ENV_FILE} ]; then
	source ${DOCKER_ENV_FILE}
else
	# No environment file: nothing to do
	reset_docker_env
	unlock_docker_env
	return
fi

# List the bridges this daemon declares, and drop the networks it no longer
# uses. In root mode its bridges live in the BuildBox container network
# namespace, which is the host one: whatever is left behind survives the
# container, then collides with the host Docker daemon and with the next
# BuildBox instances (a duplicate route makes containers unreachable).
docker_bridges=""
if [ ${DOCKER_ROOTLESS} -eq 0 ] && [ -S "${DOCKER_SOCK_FILE}" ]; then
	while read -r network_id; do
		[ -z "${network_id}" ] && continue
		bridge_name=$(docker -H "${DOCKER_HOST}" network inspect \
			-f '{{index .Options "com.docker.network.bridge.name"}}' \
			"${network_id}" 2>/dev/null) || true
		if [ -z "${bridge_name}" ]; then
			# Default name given by Docker to a network bridge
			bridge_name="br-${network_id:0:12}"
		fi
		docker_bridges+="${bridge_name} "
	done < <(docker -H "${DOCKER_HOST}" network ls \
		--filter driver=bridge --format '{{.ID}}' 2>/dev/null)
	docker -H "${DOCKER_HOST}" network prune --force > /dev/null 2>&1 || true
fi

# Stop Docker daemon
if [ -f "${DOCKER_PID_FILE}" ]; then
	pid=$(cat ${DOCKER_PID_FILE})
	ps -p ${pid} > /dev/null 2>&1
	if [ ${DOCKER_ROOTLESS} -eq 0 ]; then
		SUDO="sudo"
	fi
	if [ $? -eq 0 ]; then
		${SUDO} kill ${pid}
		# Docker daemon deletes ${DOCKER_PID_FILE} when terminating
		inotifywait -q -q -e delete_self -t 5 ${DOCKER_PID_FILE}
		if [ $? -eq 2 ]; then
			echo "Docker daemon is terminating for target ${BB_TARGET}, please wait..."
			inotifywait -e delete_self -t 25 ${DOCKER_PID_FILE} > /dev/null 2>&1
			if [ $? -ne 0 ] && [ -f ${DOCKER_PID_FILE} ]; then
				echo "Unable to terminate Docker daemon"
				reset_docker_env
				unlock_docker_env
				return 1
			fi
		fi

		retries=0
		while [ -f "${DOCKER_PID_FILE}" ]; do
			inotifywait -q -q -e delete_self -t 1 ${DOCKER_PID_FILE}
			((retries=retries+1))
			if [ $retries -eq 5 ]; then
				echo "Docker daemon is terminating for target ${BB_TARGET}, please wait..."
			fi
		done
	else
		${SUDO} rm ${DOCKER_PID_FILE}
	fi
fi

# Remove the bridges the daemon left behind. Only an unused one is removed: a
# bridge still having interfaces attached belongs to containers which outlived
# the daemon, and removing it would cut them off.
if [ ${DOCKER_ROOTLESS} -eq 0 ]; then
	for bridge_name in ${docker_bridges} ${DOCKER_BRIDGE_NAME}; do
		[ -z "${bridge_name}" ] && continue
		ip link show "${bridge_name}" > /dev/null 2>&1 || continue
		if [ -n "$(ip -oneline link show master "${bridge_name}" 2>/dev/null || true)" ]; then
			continue
		fi
		sudo ip link delete "${bridge_name}" > /dev/null 2>&1 || true
	done
fi

# Umount Docker data root if needed
if [ ${DOCKER_ROOTLESS} -eq 0 ]; then
	if [ -d "${DOCKER_DATA_ROOT}" ]; then
		mountpoint -q "${DOCKER_DATA_ROOT}"
		if [ $? -eq 0 ]; then
			sudo umount "${DOCKER_DATA_ROOT}"
		fi
	fi
fi

# Give permissions for buildbox user to manage all Docker created files
if [ -d "${DOCKER_EXEC_ROOT}" ]; then
	sudo setfacl -R -m u:buildbox:rwX ${DOCKER_EXEC_ROOT}
fi
if [ -d "${DOCKER_DATA_ROOT}" ]; then
	sudo setfacl -R -m u:buildbox:rwX ${DOCKER_DATA_ROOT}
	sudo chmod -R o-t ${DOCKER_DATA_ROOT}
fi
if [ -d "${DOCKER_CONFIG_DIR}" ]; then
	sudo setfacl -R -m u:buildbox:rwX ${DOCKER_CONFIG_DIR}
fi
if [ -d "${DOCKER_LOGS_DIR}" ]; then
	sudo setfacl -R -m u:buildbox:rwX ${DOCKER_LOGS_DIR}
fi

# Cleanup
if [ -d "${DOCKER_EXEC_ROOT}" ]; then
	rm -rf "${DOCKER_EXEC_ROOT}"
fi
reset_docker_env
unlock_docker_env
