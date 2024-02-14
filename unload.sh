tool_dir="$( cd "$( dirname "${BASH_SOURCE[0]:-$0}" )" && pwd )"
source ${tool_dir}/_common.sh

if ! lock_docker_env; then
	# Docker daemon stop already handled by another instance: nothing to do
	reset_docker_env
	return
fi

# Load environment
if [ ! -L "${DOCKER_ENV_LINK}" ]; then
	# No environment link: nothing to do
	reset_docker_env
	unlock_docker_env
	return
fi
DOCKER_ENV_FILE=$(readlink ${DOCKER_ENV_LINK})
if [ -f ${DOCKER_ENV_FILE} ]; then
	source ${DOCKER_ENV_FILE}
else
	# No environment file: nothing to do
	reset_docker_env
	unlock_docker_env
	return
fi
if [ ${DOCKER_ROOTLESS} -eq 0 ]; then
	SUDO="sudo"
fi

# Stop Docker daemon
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
