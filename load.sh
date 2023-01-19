export DOCKER_CONFIG_FILE=${BB_TARGET_BUILD_DIR}/etc/docker/daemon.json
export DOCKER_CONFIG_DIR=${BB_TARGET_BUILD_DIR}/etc
export DOCKER_TLS_CA_FILE=${BB_TARGET_BUILD_DIR}/etc/docker/ca.pem
export DOCKER_TLS_CERT_FILE=${BB_TARGET_BUILD_DIR}/etc/docker/cert.pem
export DOCKER_TLS_KEY_FILE=${BB_TARGET_BUILD_DIR}/etc/docker/key.pem
export DOCKER_DATA_ROOT=${BB_TARGET_BUILD_DIR}/var/lib/docker
export DOCKER_EXEC_ROOT=${BB_TARGET_BUILD_DIR}/var/run/docker
export DOCKER_PID_FILE=${DOCKER_EXEC_ROOT}/docker.pid
export DOCKER_SOCK_FILE=${DOCKER_EXEC_ROOT}/docker.sock
export DOCKER_LOGS_FILE=${BB_TARGET_BUILD_DIR}/var/log/docker.log
export DOCKER_LOGS_DIR=$(dirname ${DOCKER_LOGS_FILE})
export DOCKER_HOST=unix://${DOCKER_SOCK_FILE}

which dockerd-rootless.sh > /dev/null 2>&1
if [ $? -eq 0 ]; then
	export DOCKER_ROOTLESS=1
else
	SUDO="sudo"
fi

if [ -f ${DOCKER_PID_FILE} ]; then
	pid=$(cat ${DOCKER_PID_FILE})
	ps -p ${pid} > /dev/null 2>&1
	if [ $? -eq 0 ]; then
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
	echo "{}" > ${DOCKER_CONFIG_FILE}
fi

if [ ! -z "${DOCKER_ROOTLESS}" ]; then
	DOCKERD_CMD="dockerd-rootless.sh"
else
	DOCKERD_CMD="sudo dockerd"
fi
(
	XDG_RUNTIME_DIR=${DOCKER_EXEC_ROOT} \
	XDG_CONFIG_HOME=${DOCKER_CONFIG_DIR} \
	eval ${DOCKERD_CMD} \
		--pidfile ${DOCKER_PID_FILE} \
		--exec-root ${DOCKER_EXEC_ROOT} \
		--data-root ${DOCKER_DATA_ROOT} \
		--config-file ${DOCKER_CONFIG_FILE} \
		--userland-proxy-path $(which rootlesskit-docker-proxy) \
		--tlscacert ${DOCKER_TLS_CA_FILE} \
		--tlscert ${DOCKER_TLS_CERT_FILE} \
		--tlskey ${DOCKER_TLS_KEY_FILE} \
		--host ${DOCKER_HOST} \
&) > ${DOCKER_LOGS_FILE} 2>&1

inotifywait -q -q -e close_write -t 5 --include $(basename ${DOCKER_PID_FILE}) ${DOCKER_EXEC_ROOT}
if [ $? -eq 2 ]; then
	echo "Docker daemon is starting for target ${BB_TARGET}, please wait..."
	inotifywait -q -q -e close_write -t 25 --include $(basename ${DOCKER_PID_FILE}) ${DOCKER_EXEC_ROOT}
	if [ $? -ne 0 ]; then
		echo "Unable to start Docker daemon"
		return 1
	fi
fi
