#!/bin/bash -eu

if [ "${TRAVIS_GO_VERSION}" != "${ARTIFACT_GO_VERSION}" ]; then
    exit 0
fi

DOCKER_REPO="docker.ci.diabeloop.eu/${TRAVIS_REPO_SLUG#*/}"

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

    # Build Docker images
    echo "Build Docker images"
    docker build --tag "${DOCKER_REPO}:development" --target=development .
    docker build --tag "${DOCKER_REPO}" .
fi

if [ "${TRAVIS_BRANCH:-}" == "dblp" -a "${TRAVIS_PULL_REQUEST_BRANCH:-}" == "" -o -n "${TRAVIS_TAG:-}" ]; then
    # Publish Docker images
    DOCKER_TAG=${TRAVIS_TAG/dblp./}

    echo "${DOCKER_PASSWORD}" | docker login --username "${DOCKER_USERNAME}" --password-stdin ${DOCKER_REPO}

    if [ "${TRAVIS_BRANCH:-}" == "dblp" -a "${TRAVIS_PULL_REQUEST_BRANCH:-}" == "" ]; then
        echo "Push images to ${DOCKER_REPO}"
        docker push "${DOCKER_REPO}"
    fi
    if [ -n "${DOCKER_TAG:-}" ]; then
        echo "Tag and push image to ${DOCKER_REPO}"
        docker tag "${DOCKER_REPO}" "${DOCKER_REPO}:${DOCKER_TAG}"
        docker push "${DOCKER_REPO}:${DOCKER_TAG}"
    fi
fi
