if [ -z "${DOCKER_ROOTLESS}" ]; then
	SUDO="sudo"
fi

if [ -f "${DOCKER_PID_FILE}" ]; then
	pid=$(cat ${DOCKER_PID_FILE})
	ps -p ${pid} > /dev/null 2>&1
	if [ $? -eq 0 ]; then
		${SUDO} kill ${pid}
		# Docker daemon deletes ${DOCKER_PID_FILE} when terminating
		inotifywait -q -q -e delete_self -t 5 ${DOCKER_PID_FILE}
		if [ $? -eq 2 ]; then
			echo "Docker daemon is terminating for target ${BB_TARGET}, please wait..."
			inotifywait -e delete_self -t 25 ${DOCKER_PID_FILE} > /dev/null 2>&1
			if [ $? -ne 0 ] && [ -f ${DOCKER_PID_FILE} ]; then
				echo "Unable to terminate Docker daemon"
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

if [ -d "${DOCKER_EXEC_ROOT}" ]; then
	${SUDO} chmod -R u+rwX "${DOCKER_EXEC_ROOT}" > /dev/null 2>&1
	${SUDO} rm -rf "${DOCKER_EXEC_ROOT}"
fi
if [ -d "${DOCKER_DATA_ROOT}" ]; then
	${SUDO} chmod -R u+rwX "${DOCKER_DATA_ROOT}" > /dev/null 2>&1
fi
if [ -z "${DOCKER_ROOTLESS}" ]; then
	if [ -d "${DOCKER_CONFIG_DIR}" ]; then
		sudo chown -R buildbox:buildbox "${DOCKER_CONFIG_DIR}"
	fi
	if [ -d "${DOCKER_DATA_ROOT}" ]; then
		mountpoint -q "${DOCKER_DATA_ROOT}"
		if [ $? -eq 0 ]; then
			sudo umount "${DOCKER_DATA_ROOT}"
		fi
		sudo chown -R buildbox:buildbox "${DOCKER_DATA_ROOT}"
	fi
	if [ -d "${DOCKER_LOGS_DIR}" ]; then
		sudo chown -R buildbox:buildbox "${DOCKER_LOGS_DIR}"
	fi
fi

unset DOCKER_CONFIG_FILE
unset DOCKER_CONFIG_DIR
unset DOCKER_DATA_ROOT
unset DOCKER_EXEC_ROOT
unset DOCKER_PID_FILE
unset DOCKER_SOCK_FILE
unset DOCKER_LOGS_FILE
unset DOCKER_LOGS_DIR
unset DOCKER_HOST
unset DOCKER_ROOTLESS
unset BUILDX_CONFIG
