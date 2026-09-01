# Docker tools for BuildBox - load script
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

# Environment definition
# try to load environment from file
if [ -f ${DOCKER_ENV_FILE} ]; then
	source ${DOCKER_ENV_FILE}
	if [ -z "${DOCKER_CONFIG_FILE}" ] ||
		[ -z "${DOCKER_CONFIG_DIR}" ] ||
		[ -z "${DOCKER_TLS_CA_FILE}" ] ||
		[ -z "${DOCKER_TLS_CERT_FILE}" ] ||
		[ -z "${DOCKER_TLS_KEY_FILE}" ] ||
		[ -z "${DOCKER_DATA_ROOT}" ] ||
		[ -z "${DOCKER_LOGS_FILE}" ] ||
		[ -z "${DOCKER_LOGS_DIR}" ] ||
		[ -z "${BUILDX_CONFIG}" ] ||
		[ -z "${DOCKER_EXEC_ROOT}" ] ||
		[ -z "${DOCKER_PID_FILE}" ] ||
		[ -z "${DOCKER_SOCK_FILE}" ] ||
		[ -z "${DOCKER_HOST}" ] ||
		[ -z "${DOCKER_NETWORK_SLOT}" ] ||
		[ -z "${DOCKER_BRIDGE_NAME}" ] ||
		[ -z "${DOCKER_BRIDGE_ADDRESS}" ] ||
		[ -z "${DOCKER_BRIDGE_SUBNET}" ] ||
		[ -z "${DOCKER_ADDRESS_POOL_BASE}" ] ||
		[ -z "${DOCKER_ADDRESS_POOL_SIZE}" ] ||
		[ -z "${DOCKER_ROOTLESS}" ]; then
		GENERATE_ENV=1
	else
		GENERATE_ENV=0
	fi
else
	GENERATE_ENV=1
fi
# else, generate it
if [ ${GENERATE_ENV} -eq 1 ]; then
	DOCKER_ENV=""
	DOCKER_ENV_RESET=""
	function add_env {
		export ${1}
		DOCKER_ENV+="export ${1}"
		DOCKER_ENV+=$'\n'
		# also generate entries to later reset env
		DOCKER_ENV_RESET+="unset ${1%%=*}"
		DOCKER_ENV_RESET+=$'\n'
	}

	# Config paths
	add_env DOCKER_CONFIG_FILE=${BB_TARGET_BUILD_DIR}/etc/docker/daemon.json
	add_env DOCKER_CONFIG_DIR=${BB_TARGET_BUILD_DIR}/etc
	add_env DOCKER_TLS_CA_FILE=${BB_TARGET_BUILD_DIR}/etc/docker/ca.pem
	add_env DOCKER_TLS_CERT_FILE=${BB_TARGET_BUILD_DIR}/etc/docker/cert.pem
	add_env DOCKER_TLS_KEY_FILE=${BB_TARGET_BUILD_DIR}/etc/docker/key.pem
	add_env DOCKER_DATA_ROOT=${BB_TARGET_BUILD_DIR}/var/lib/docker
	add_env DOCKER_LOGS_FILE=${BB_TARGET_BUILD_DIR}/var/log/docker.log
	add_env DOCKER_LOGS_DIR=$(dirname ${DOCKER_LOGS_FILE})
	add_env BUILDX_CONFIG=${BB_TARGET_BUILD_DIR}/etc/docker/buildx

	# Runtime paths
	add_env DOCKER_EXEC_ROOT=$(mktemp -d)
	add_env DOCKER_PID_FILE=${DOCKER_EXEC_ROOT}/docker.pid
	add_env DOCKER_SOCK_FILE=${DOCKER_EXEC_ROOT}/docker.sock
	add_env DOCKER_HOST=unix://${DOCKER_SOCK_FILE}

	# Network ranges, dedicated to this target.
	# In root mode the daemon runs in the BuildBox container network namespace,
	# which is the host one: its bridge and its subnets must collide neither
	# with the host Docker daemon (which owns 'docker0' and the default Docker
	# ranges) nor with another BuildBox instance. Each target gets a slot in
	# 10.192.0.0/11, derived from its identity so that it is stable across
	# daemon restarts, which the daemon requires for its bridge.
	network_slot=""
	if [ -n "${BB_TARGET_VAR_DOCKER_NETWORK_SLOT}" ]; then
		case "${BB_TARGET_VAR_DOCKER_NETWORK_SLOT}" in
			''|*[!0-9]*)
				echo "Invalid BB_TARGET_VAR_DOCKER_NETWORK_SLOT, expected 0 to 31" ;;
			*)
				if [ ${BB_TARGET_VAR_DOCKER_NETWORK_SLOT} -le 31 ]; then
					network_slot=${BB_TARGET_VAR_DOCKER_NETWORK_SLOT}
				else
					echo "Invalid BB_TARGET_VAR_DOCKER_NETWORK_SLOT, expected 0 to 31"
				fi ;;
		esac
	fi
	if [ -z "${network_slot}" ]; then
		network_slot=$(printf '%s' "${BB_PROJECT_DIR}/${BB_TARGET}" | md5sum | cut -c1-8)
		network_slot=$(( 0x${network_slot} % 32 ))
	fi
	add_env DOCKER_NETWORK_SLOT=${network_slot}
	add_env DOCKER_BRIDGE_NAME=bbxdocker${network_slot}
	add_env DOCKER_BRIDGE_ADDRESS=10.$(( 192 + network_slot )).0.1/24
	add_env DOCKER_BRIDGE_SUBNET=10.$(( 192 + network_slot )).0.0/24
	add_env DOCKER_ADDRESS_POOL_BASE=10.$(( 192 + network_slot )).128.0/17
	add_env DOCKER_ADDRESS_POOL_SIZE=24

	if [ -z "${BB_TARGET_VAR_DOCKER_ROOTLESS}" ] || [[ "${BB_TARGET_VAR_DOCKER_ROOTLESS}" != "1" ]]; then
		add_env DOCKER_ROOTLESS=0
	else
		add_env DOCKER_ROOTLESS=1
	fi
fi

# Check if another instance is already doing the job
if ! lock_docker_env; then
	return
fi

# Store env file
if [ ${GENERATE_ENV} -eq 1 ]; then
	mkdir -p ${BB_TARGET_BUILD_DIR}
	echo "${DOCKER_ENV}" > ${DOCKER_ENV_FILE}
	echo "${DOCKER_ENV_RESET}" > ${DOCKER_ENV_RESET_FILE}
fi

# If Docker daemon is already running, stop here
if [ -f ${DOCKER_PID_FILE} ]; then
	pid=$(cat ${DOCKER_PID_FILE})
	ps -p ${pid} > /dev/null 2>&1
	if [ $? -eq 0 ]; then
		unlock_docker_env
		return 0
	fi
fi

if [ -d "${DOCKER_EXEC_ROOT}" ]; then
	sudo chmod -R u+rwX "${DOCKER_EXEC_ROOT}"
	sudo rm -rf "${DOCKER_EXEC_ROOT}"
fi
mkdir -p ${DOCKER_CONFIG_DIR}
mkdir -p ${DOCKER_DATA_ROOT}
mkdir -p ${DOCKER_EXEC_ROOT}
mkdir -p ${DOCKER_LOGS_DIR}
mkdir -p $(dirname ${DOCKER_CONFIG_FILE})
# Daemon configuration file, generated at each start from the provided one (which
# must not be modified) completed with the networks pool dedicated to the target:
# the daemon only accepts that pool as a configuration key.
provided_config_file=""
if [ -n "${BB_TARGET_VAR_DOCKER_CONFIG_FILE}" ]; then
	provided_config_file=$(eval "echo ${BB_TARGET_VAR_DOCKER_CONFIG_FILE}")
	if [ ! -f "${provided_config_file}" ]; then
		echo "Docker config file not found at ${provided_config_file} ! aborting Docker daemon startup"
		unlock_docker_env
		return
	fi
fi
docker_config="{}"
if [ -n "${provided_config_file}" ]; then
	docker_config=$(cat "${provided_config_file}")
fi
if [ ${DOCKER_ROOTLESS} -eq 0 ]; then
	if command -v jq > /dev/null 2>&1; then
		# A pool defined by the provided file wins
		merged_config=$(printf '%s' "${docker_config}" | jq \
			--arg base "${DOCKER_ADDRESS_POOL_BASE}" \
			--argjson size ${DOCKER_ADDRESS_POOL_SIZE} \
			'if has("default-address-pools") then . else
				. + {"default-address-pools": [{base: $base, size: $size}]} end' \
			2>/dev/null) || true
		if [ -n "${merged_config}" ]; then
			docker_config="${merged_config}"
		else
			echo "Warning: unable to set Docker networks pool for target ${BB_TARGET}"
		fi
	else
		echo "Warning: jq is missing, Docker networks of target ${BB_TARGET} keep the default ranges"
	fi
fi
# Removed first: a previous version of this tool made it a symlink to the
# provided file, which a redirection would overwrite
rm -f ${DOCKER_CONFIG_FILE}
printf '%s\n' "${docker_config}" > ${DOCKER_CONFIG_FILE}

# Start Docker daemon
if [ ${DOCKER_ROOTLESS} -eq 1 ]; then
	DOCKERD_CMD="dockerd-rootless.sh"
	DOCKER_PROXY="rootlesskit-docker-proxy"
	# Rootless daemon runs in its own network namespace: nothing to isolate
	DOCKERD_NETWORK_ARGS=""
else
	DOCKERD_CMD="sudo dockerd"
	DOCKER_PROXY="docker-proxy"
	# The networks pool is only a configuration key, see the config file below
	DOCKERD_NETWORK_ARGS="--bridge ${DOCKER_BRIDGE_NAME}"
	# The daemon uses the bridge as it is, so create it with its address.
	# Failures are tolerated on purpose: an ERR would release the lock while
	# this script keeps running
	if ! ip link show ${DOCKER_BRIDGE_NAME} > /dev/null 2>&1; then
		sudo ip link add name ${DOCKER_BRIDGE_NAME} type bridge || true
	fi
	if ! ip -oneline addr show ${DOCKER_BRIDGE_NAME} | grep -q "${DOCKER_BRIDGE_ADDRESS}"; then
		sudo ip addr add ${DOCKER_BRIDGE_ADDRESS} dev ${DOCKER_BRIDGE_NAME} > /dev/null 2>&1 || true
	fi
	sudo ip link set ${DOCKER_BRIDGE_NAME} up || true
	# A range routed by another interface makes the daemon containers
	# unreachable, without any error reported by Docker
	network_conflict=$(ip -oneline route show ${DOCKER_BRIDGE_SUBNET} \
		| grep -v " dev ${DOCKER_BRIDGE_NAME} " | head -1)
	if [ -n "${network_conflict}" ]; then
		echo "Warning: ${DOCKER_BRIDGE_SUBNET} is already routed: ${network_conflict}"
		echo "         Docker containers of target ${BB_TARGET} may be unreachable."
		echo "         Set BB_TARGET_VAR_DOCKER_NETWORK_SLOT to a free slot (0 to 31)."
	fi
fi
export XDG_RUNTIME_DIR=${DOCKER_EXEC_ROOT}
export XDG_CONFIG_HOME=${DOCKER_CONFIG_DIR}
# The daemon outlives the command which starts it, so it must inherit nothing
# from it. A descriptor left open, the pipe of a package build for instance,
# would keep that command waiting for the whole life of the daemon. Hence the
# exec, which leaves no shell behind and drops the descriptors a shell keeps for
# itself, plus an explicit stdin.
(
	exec 0< /dev/null
	eval exec ${DOCKERD_CMD} \
		--pidfile ${DOCKER_PID_FILE} \
		--exec-root ${DOCKER_EXEC_ROOT} \
		--data-root ${DOCKER_DATA_ROOT} \
		--config-file ${DOCKER_CONFIG_FILE} \
		--userland-proxy-path $(which ${DOCKER_PROXY}) \
		${DOCKERD_NETWORK_ARGS} \
		--tlscacert ${DOCKER_TLS_CA_FILE} \
		--tlscert ${DOCKER_TLS_CERT_FILE} \
		--tlskey ${DOCKER_TLS_KEY_FILE} \
		--host ${DOCKER_HOST}
) > ${DOCKER_LOGS_FILE} 2>&1 &

unset XDG_RUNTIME_DIR
unset XDG_CONFIG_HOME

retries=0
while [ ! -f "${DOCKER_PID_FILE}" ]; do
	inotifywait -q -q -e close_write -t 1 --include $(basename ${DOCKER_PID_FILE}) ${DOCKER_EXEC_ROOT}
	((retries=retries+1))
	if [ $retries -eq 5 ]; then
		echo "Docker daemon is starting for target ${BB_TARGET}, please wait..."
	fi
	if [ ${retries} -ge 60 ]; then
		echo "Docker daemon did not start for target ${BB_TARGET}, last log lines:"
		tail -5 ${DOCKER_LOGS_FILE} 2>/dev/null | sed 's/^/  /'
		echo "  full log: ${DOCKER_LOGS_FILE}"
		unlock_docker_env
		return
	fi
done

unlock_docker_env

