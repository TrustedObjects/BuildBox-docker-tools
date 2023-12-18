DOCKER_ENV_LINK=${BB_TARGET_BUILD_DIR}/docker.env
DOCKER_ENV_RESET_FILE=${BB_TARGET_BUILD_DIR}/docker.env.reset
DOCKER_ENV_LOCK=${BB_TARGET_BUILD_DIR}/docker.env.lock

function reset_docker_env {
	if [ -f ${DOCKER_ENV_RESET_FILE} ]; then
		source ${DOCKER_ENV_RESET_FILE}
	fi
}

function lock_docker_env {
	mkdir -p $(dirname ${DOCKER_ENV_LOCK})
	mkdir ${DOCKER_ENV_LOCK} 2>/dev/null;
}

function unlock_docker_env {
	rmdir ${DOCKER_ENV_LOCK}
}

