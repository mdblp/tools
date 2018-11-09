#!/bin/bash -eu

if [ "${TRAVIS_NODE_VERSION}" != "${ARTIFACT_NODE_VERSION}" ]; then
    exit 0
fi

if [ -n "${TRAVIS_TAG:-}" ]; then
    ARTIFACT_DIR='deploy'

    APP="${TRAVIS_REPO_SLUG#*/}"
    APP_DIR="${ARTIFACT_DIR}/${APP}"
    APP_TAG="${APP}-${TRAVIS_TAG}"

    TMP_DIR="/tmp/${TRAVIS_REPO_SLUG}"

    if [ -f '.artifactignore' ]; then
        RSYNC_OPTIONS='--exclude-from=.artifactignore'
    else
        RSYNC_OPTIONS=''
    fi

    rm -rf "${ARTIFACT_DIR}/" "${TMP_DIR}/" || { echo 'ERROR: Unable to delete artifact and tmp directories'; exit 1; }
    mkdir -p "${APP_DIR}/" "${TMP_DIR}/" || { echo 'ERROR: Unable to create app and tmp directories'; exit 1; }

    ./build.sh || { echo 'ERROR: Unable to build project'; exit 1; }

    rsync -a ${RSYNC_OPTIONS} . "${TMP_DIR}/${APP_TAG}/" || { echo 'ERROR: Unable to copy files'; exit 1; }

    tar -c -z -f "${APP_DIR}/${APP_TAG}.tar.gz" -C "${TMP_DIR}" "${APP_TAG}" || { echo 'ERROR: Unable to create artifact'; exit 1; }

    rm -rf "${TMP_DIR}/"
fi

if [ "${TRAVIS_BRANCH:-}" == "master" -a "${TRAVIS_PULL_REQUEST_BRANCH:-}" == "" -o -n "${TRAVIS_TAG:-}" ]; then
    DOCKER_SERVER="docker.ci.diabeloop.eu"
    DOCKER_REPO="${DOCKER_SERVER}/${TRAVIS_REPO_SLUG#*/}"

    echo "${DOCKER_PASSWORD}" | docker login --username "${DOCKER_USERNAME}" --password-stdin ${DOCKER_SERVER}

    docker build --tag "${DOCKER_REPO}" .
    if [ "${TRAVIS_BRANCH:-}" == "dblp" -a "${TRAVIS_PULL_REQUEST_BRANCH:-}" == "" ]; then
        docker push "${DOCKER_REPO}"
    fi
    if [ -n "${TRAVIS_TAG:-}" ]; then
        docker tag "${DOCKER_REPO}" "${DOCKER_REPO}:${TRAVIS_TAG}"
        docker push "${DOCKER_REPO}:${TRAVIS_TAG}"
    fi
fi
