#!/bin/bash -eux

pushDocker() {
    # $1 = docker registry
    # $2 = registry username
    # $3 = registry password
    # $4 = image repository
    # $5 = image version
    local img_tag="$1/$4:$5"
    echo "Tag image"
    docker tag "$4" "${img_tag}"
    echo "Login, push and logout"
    echo "$3" | docker login --username "$2" --password-stdin $1
    docker push "${img_tag}"
    docker logout $1
}

main() {
    if [ "${TRAVIS_GO_VERSION}" != "${ARTIFACT_GO_VERSION}" ]; then
        exit 0
    fi

    # If project has set BUILD_OPENAPI_DOC environment variable to true, then we build the openapi doc
    OPENAPI_SCRIPT=${OPENAPI_SCRIPT:-buildDoc.sh}
    if [ ${BUILD_OPENAPI_DOC:-false} = true -a -f ${OPENAPI_SCRIPT} ]; then
        echo "Build documentation"
        ./${OPENAPI_SCRIPT}
    fi

    # If project has set BUILD_SOUP environment variable to true, then we build the SOUPs list
    SOUP_SCRIPT=${SOUP_SCRIPT:-buildSoup.sh}
    if [ ${BUILD_SOUP:-false} = true -a -f ${SOUP_SCRIPT} ]; then
        echo "Build SOUPs list"
        ./${SOUP_SCRIPT}
    fi

    if [ -n "${TRAVIS_TAG:-}" ]; then
        ARTIFACT_DIR='deploy'

        APP="${TRAVIS_REPO_SLUG#*/}"
        APP_DIR="${ARTIFACT_DIR}/${APP}"
        APP_TAG="${APP}-${TRAVIS_TAG}"

        rm -rf "${ARTIFACT_DIR}/" || { echo 'ERROR: Unable to delete artifact directory'; exit 1; }
        mkdir -p "${APP_DIR}/" || { echo 'ERROR: Unable to create app directory'; exit 1; }

        ./build.sh || { echo 'ERROR: Unable to build project'; exit 1; }

        mv dist "${APP_DIR}/${APP_TAG}" || { echo 'ERROR: Unable to move app artifact directory'; exit 1; }

        tar -c -z -f "${APP_DIR}/${APP_TAG}.tar.gz" -C "${APP_DIR}" "${APP_TAG}" || { echo 'ERROR: Unable to create artifact'; exit 1; }
    fi

    # Build Docker image whatever (failfast strategy)
    local docker_repo="${TRAVIS_REPO_SLUG#*/}"
    echo "Build Docker image ${docker_repo}"
    docker build --tag "${docker_repo}" .

    # Security scan on the built image
    echo "Security scan using Trivy container"
    local trivy_version=$(curl --silent "https://api.github.com/repos/aquasecurity/trivy/releases/latest" | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')
    docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v ${HOME}/.cache:${HOME}/.cache/ aquasec/trivy:${trivy_version} image --exit-code 1 --severity CRITICAL,HIGH ${docker_repo}

    # Push docker image only when we have a tag
    if [ -n "${TRAVIS_TAG}" ]; then
        echo "Docker push"
        # This line below removes "dblp." from the TRAVIS_TAG
        local image_version=${TRAVIS_TAG/dblp./}

        # We push to Default if the registry host is set
        if [[ ${DOCKER_REGISTRY}:-""} != "" ]]; then
            echo "Push image to Default registry (${DOCKER_REGISTRY})"
            pushDocker ${DOCKER_REGISTRY} ${DOCKER_USERNAME} ${DOCKER_PASSWORD} ${docker_repo} ${image_version}
        else
            echo "Skipping docker push to Default registry"
        fi

        # We push to Operations registry host is set and if we don't have a tag for release candidate
        if [[ ${OPS_DOCKER_REGISTRY:-""} != "" && ! ${TRAVIS_TAG} =~ rc[0-9] ]]; then
            echo "Push image to Operations registry (${OPS_DOCKER_REGISTRY})"
            pushDocker ${OPS_DOCKER_REGISTRY} ${OPS_DOCKER_USERNAME} ${OPS_DOCKER_PASSWORD} ${docker_repo} ${image_version}
        else
            echo "Skipping push to Operations registry"
        fi
    else
        echo "Not a tag, not pushing the docker image"
    fi
}

main
