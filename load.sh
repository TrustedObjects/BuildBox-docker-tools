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
		DOCKER_ENV_RESET+="unset ${1%=*}"
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

	if [ -z "${BB_TARGET_VAR_DOCKER_ROOTLESS}" ] || [[ "${BB_TARGET_VAR_DOCKER_ROOTLESS}" != "1" ]]; then
		add_env DOCKER_ROOTLESS=0
		SUDO="sudo"
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
	${SUDO} chmod -R u+rwX "${DOCKER_EXEC_ROOT}"
	${SUDO} rm -rf "${DOCKER_EXEC_ROOT}"
fi
mkdir -p ${DOCKER_CONFIG_DIR}
mkdir -p ${DOCKER_DATA_ROOT}
mkdir -p ${DOCKER_EXEC_ROOT}
mkdir -p ${DOCKER_LOGS_DIR}
mkdir -p $(dirname ${DOCKER_CONFIG_FILE})
if [ ! -f ${DOCKER_CONFIG_FILE} ]; then
	if [ -z "${BB_TARGET_VAR_DOCKER_CONFIG_FILE}" ]; then
		echo "{}" > ${DOCKER_CONFIG_FILE}
	else
		provided_config_file=$(eval "echo ${BB_TARGET_VAR_DOCKER_CONFIG_FILE}")
		if [ ! -f "${provided_config_file}" ]; then
			echo "Docker config file not found at ${provided_config_file} ! aborting Docker daemon startup"
			unlock_docker_env
			return
		fi
		ln -s "${provided_config_file}" ${DOCKER_CONFIG_FILE}
	fi
fi

# Start Docker daemon
if [ ${DOCKER_ROOTLESS} -eq 1 ]; then
	DOCKERD_CMD="dockerd-rootless.sh"
	DOCKER_PROXY="rootlesskit-docker-proxy"
else
	DOCKERD_CMD="sudo dockerd"
	DOCKER_PROXY="docker-proxy"
fi
export XDG_RUNTIME_DIR=${DOCKER_EXEC_ROOT}
export XDG_CONFIG_HOME=${DOCKER_CONFIG_DIR}
(
	eval ${DOCKERD_CMD} \
		--pidfile ${DOCKER_PID_FILE} \
		--exec-root ${DOCKER_EXEC_ROOT} \
		--data-root ${DOCKER_DATA_ROOT} \
		--config-file ${DOCKER_CONFIG_FILE} \
		--userland-proxy-path $(which ${DOCKER_PROXY}) \
		--tlscacert ${DOCKER_TLS_CA_FILE} \
		--tlscert ${DOCKER_TLS_CERT_FILE} \
		--tlskey ${DOCKER_TLS_KEY_FILE} \
		--host ${DOCKER_HOST} \
&) > ${DOCKER_LOGS_FILE} 2>&1
unset XDG_RUNTIME_DIR
unset XDG_CONFIG_HOME

retries=0
while [ ! -f "${DOCKER_PID_FILE}" ]; do
	inotifywait -q -q -e close_write -t 1 --include $(basename ${DOCKER_PID_FILE}) ${DOCKER_EXEC_ROOT}
	((retries=retries+1))
	if [ $retries -eq 5 ]; then
		echo "Docker daemon is starting for target ${BB_TARGET}, please wait..."
	fi
done

unlock_docker_env

