# Environment definition
DOCKER_ENV_FILE=${TMPDIR}/docker.env
DOCKER_ENV=""
function add_env {
	export ${1}
	DOCKER_ENV+="export ${1}"
	DOCKER_ENV+=$'\n'
}
if [ -f ${DOCKER_ENV_FILE} ]; then
	source ${DOCKER_ENV_FILE}
else
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
	add_env DOCKER_EXEC_ROOT=${TMPDIR}/docker
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

if [ -f ${DOCKER_PID_FILE} ]; then
	pid=$(cat ${DOCKER_PID_FILE})
	ps -p ${pid} > /dev/null 2>&1
	if [ $? -eq 0 ]; then
		return 0
	fi
fi

# If Docker daemon is already running, stop here
echo "${DOCKER_ENV}" > ${DOCKER_ENV_FILE}

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
	echo "{}" > ${DOCKER_CONFIG_FILE}
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
