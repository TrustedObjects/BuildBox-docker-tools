DOCKER_ENV_FILE=${BB_TARGET_BUILD_DIR}/docker.env
DOCKER_ENV_RESET_FILE=${BB_TARGET_BUILD_DIR}/docker.env.reset
DOCKER_ENV_LOCK=${BB_TARGET_BUILD_DIR}/docker.env.lock
LOCK_OWNER=0

function reset_docker_env {
	if [ -f ${DOCKER_ENV_RESET_FILE} ]; then
		source ${DOCKER_ENV_RESET_FILE}
	fi
}

function lock_docker_env {
	mkdir -p $(dirname ${DOCKER_ENV_LOCK})
	mkdir ${DOCKER_ENV_LOCK} 2>/dev/null;
	if [ $? -eq 0 ]; then
		LOCK_OWNER=1
		return 0
	else
		return 1
	fi
}

function unlock_docker_env {
	LOCK_OWNER=0
	rmdir ${DOCKER_ENV_LOCK} > /dev/null 2>&1
}

function docker_tools_error_handler {
	if [ ${LOCK_OWNER} -ne 0 ]; then
		unlock_docker_env
	fi
}
trap 'docker_tools_error_handler' ERR
