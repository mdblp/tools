#!/bin/bash -eu

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

triggerSecurityScan() {
    # $1 = docker image name
    # $2 = docker image tag
    echo "Trigger security scan on image $1:$2"
    # Trigger scan at Operations registry
    curl -X POST \
        -F token=${OPS_SCAN_TOKEN} \
        -F ref=master \
        -F "variables[IMAGE_NAME]=$1" \
        -F "variables[IMAGE_TAG]=$2" \
        -F "variables[COMMIT_ID]=${TRAVIS_PULL_REQUEST_SHA}" \
        -F "variables[REPO_SLUG]=${TRAVIS_REPO_SLUG}" \
        -F "variables[REMOVE_IMAGE]=true" \
        https://git.coreye.fr/api/v4/projects/1433/trigger/pipeline
    # Attach new status "pending" to the commit for aquascanner context
    # Our Ops partner will update the status once the scanner is finished
    echo "Set 'pending' status to commit ${TRAVIS_PULL_REQUEST_SHA}"
    curl --location --request POST "https://api.github.com/repos/${TRAVIS_REPO_SLUG}/statuses/${TRAVIS_PULL_REQUEST_SHA}" \
        --header "Authorization: Bearer ${GITHUB_TOKEN}" \
        --header 'Content-Type: application/json' \
        --data-raw '{
            "state": "pending",
            "description": "The security scan is running!",
            "context": "aquascanner"
        }'
}

main() {
    # Print some variables, so we can debug this script if something goes wrong
    echo "ARTIFACT_NODE_VERSION: ${ARTIFACT_NODE_VERSION}"
    echo "TRAVIS_NODE_VERSION: ${TRAVIS_NODE_VERSION}"
    echo "TRAVIS_BRANCH: ${TRAVIS_BRANCH}"
    echo "TRAVIS_PULL_REQUEST: ${TRAVIS_PULL_REQUEST}"
    echo "TRAVIS_TAG: ${TRAVIS_TAG}"
    echo "TRAVIS_REPO_SLUG: ${TRAVIS_REPO_SLUG}"
    echo "TRAVIS_PULL_REQUEST_SHA: ${TRAVIS_PULL_REQUEST_SHA}"

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
    local docker_repo="${TRAVIS_REPO_SLUG#*/}"

    echo "Build docker image ${docker_repo}"
    docker build --tag "${docker_repo}" --build-arg npm_token=${NEXUS_TOKEN} .

    # Security scan on the Operations registry
    # The security scan is executed only for a PR build
    # The image has to be pushed to Operations registry to benefit from their security scanner
    if [ ${SECURITY_SCAN:-true} = true ] && [ "${TRAVIS_PULL_REQUEST}" != "false" ]; then
        echo "Security scan"
        local scanTag="${TRAVIS_PULL_REQUEST_SHA}-scanOnly"
        if [ ${OPS_DOCKER_REGISTRY:-""} != "" ]; then
            echo "Push image to Operations registry (${OPS_DOCKER_REGISTRY})"
            pushDocker ${OPS_DOCKER_REGISTRY} ${OPS_DOCKER_USERNAME} ${OPS_DOCKER_PASSWORD} ${docker_repo} ${scanTag}
            triggerSecurityScan ${docker_repo} ${scanTag}
        else
            echo "OPS Docker Registry unknown. Security Scan cannot occur."
            exit 1
        fi
    else
        echo "Skipping Security Scan"
    fi

    # Push docker image only when we have a tag
    if [ -n "${TRAVIS_TAG}" ]; then
        echo "Docker push"
        # This line below removes "dblp." from the TRAVIS_TAG
        local image_version=${TRAVIS_TAG/dblp./}

        # We push to Default if the registry host is set
        if [ ${DOCKER_REGISTRY:-""} != "" ]; then
            echo "Push image to Default registry (${DOCKER_REGISTRY})"
            pushDocker ${DOCKER_REGISTRY} ${DOCKER_USERNAME} ${DOCKER_PASSWORD} ${docker_repo} ${image_version}
        else
            echo "Skipping docker push to Default registry"
        fi

        # We push to Operations if the registry host is set and if we don't have a tag for release candidate
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
