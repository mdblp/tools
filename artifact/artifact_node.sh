#!/bin/bash -eu

pushDocker() {
    # $1 = docker registry
    # $2 = registry username
    # $3 = registry password
    # $4 = image repository
    # $5 = image version
    local image_name="$1/$4"
    echo "Tag image"
    docker tag "$4" "${image_name}:$5"
    echo "Login, push and logout"
    echo "$3" | docker login --username "$2" --password-stdin $1
    docker push "${image_name}"
    docker logout $1
}

main() {
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

    # If project has set BUILD_SOUP environment variable to true, then we build the SOUPs list
    if [ ${BUILD_SOUP:-false} = true ]; then
        echo "Build SOUPs list"
        npm run build-soup
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

    # Build Docker image whatever (failfast strategy)
    docker_repo="${TRAVIS_REPO_SLUG#*/}"

    echo "Build docker image ${docker_repo}"
    docker build --tag "${docker_repo}" --build-arg npm_token=${nexus_token} .

    if [ ${SECURITY_SCAN:-false} = true ]; then
        echo "Security scan"
        # Microscanner security scan on the built image
        wget -q -O scanDockerImage.sh 'https://raw.githubusercontent.com/mdblp/tools/dblp/artifact/scanDockerImage.sh'
        chmod +x scanDockerImage.sh
        MICROSCANNER_TOKEN=${MICROSCANNER_TOKEN} ./scanDockerImage.sh ${docker_repo}
    fi

    # Push docker image only when we have a tag
    # To avoid publishing 2x (on the branch build + PR) we do not do it on the PR build
    if [ -n "${TRAVIS_TAG}" -a "${TRAVIS_PULL_REQUEST:-false}" == "false" ]; then
        # This line below removes "dblp." from the TRAVIS_TAG
        image_version=${TRAVIS_TAG/dblp./}
        echo "Push image to Diabeloop registry"
        pushDocker "docker.ci.diabeloop.eu" ${DOCKER_USERNAME} ${DOCKER_PASSWORD} ${docker_repo} ${image_version}

        # We push to Pictime except if the service does not want to and if we don't have a tag for release candidate
        if [[ ${PUSH_DOCKER_PICTIME:-true} != false && ! ${TRAVIS_TAG} =~ rc[0-9] ]]; then
            echo "Push image to Pictime registry"
            pushDocker "registry.coreye.fr/diabeloop/artifacts/diabeloop_docker" ${PCT_DOCKER_USERNAME} ${PCT_DOCKER_PASSWORD} ${docker_repo} ${image_version}
        else
            echo "Skipping push on Pictime registry"
        fi
    else
        echo "Not a tag or pull request, not pushing the docker image"
    fi
}

main
