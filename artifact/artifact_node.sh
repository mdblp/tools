#!/bin/bash -eu

# Print some variables, so we can debug this script if something goes wrong
echo "ARTIFACT_NODE_VERSION: ${ARTIFACT_NODE_VERSION}"
echo "TRAVIS_NODE_VERSION: ${TRAVIS_NODE_VERSION}"
echo "TRAVIS_BRANCH: ${TRAVIS_BRANCH}"
echo "TRAVIS_PULL_REQUEST: ${TRAVIS_PULL_REQUEST}"
echo "TRAVIS_TAG: ${TRAVIS_TAG}"
echo "TRAVIS_REPO_SLUG: ${TRAVIS_REPO_SLUG}"

if [ "${TRAVIS_NODE_VERSION}" != "${ARTIFACT_NODE_VERSION}" ]; then
    exit 0
fi

# If project has set BUILD_OPENAPI_DOC environment variable to true, then we build the openapi doc
if [ ${BUILD_OPENAPI_DOC:-false} = true ]; then
    echo "Build documentation"
    npm run build-doc
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

# Build Docker image whatever
DOCKER_REPO="docker.ci.diabeloop.eu/${TRAVIS_REPO_SLUG#*/}"
echo "Building docker image"
docker build --tag "${DOCKER_REPO}" --build-arg npm_token=${nexus_token} .

if [ "${TRAVIS_BRANCH:-none}" == "dblp" -a "${TRAVIS_PULL_REQUEST:-false}" == "false" -a -n "${TRAVIS_TAG}" ]; then
    # Publish Docker image
    DOCKER_TAG=${TRAVIS_TAG/dblp./}

    echo "Docker login"
    echo "${DOCKER_PASSWORD}" | docker login --username "${DOCKER_USERNAME}" --password-stdin ${DOCKER_REPO}

    echo "Tag and push image to ${DOCKER_REPO}:${DOCKER_TAG}"
    docker tag "${DOCKER_REPO}" "${DOCKER_REPO}:${DOCKER_TAG}"
    docker push "${DOCKER_REPO}:${DOCKER_TAG}"
else
    echo "Wrong branch or pull request, not pushing the docker image"
fi
