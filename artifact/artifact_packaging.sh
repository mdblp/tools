#!/bin/bash
set -e
set -u
# Print some variables, so we can debug this script if something goes wrong
# Use default values to allow running outside travis without having to set all of them
echo "ARTIFACT_NODE_VERSION: ${ARTIFACT_NODE_VERSION:-10.0.0}"
echo "TRAVIS_NODE_VERSION: ${TRAVIS_NODE_VERSION:-0.0.0}"
echo "TRAVIS_BRANCH: ${TRAVIS_BRANCH:-}"
echo "TRAVIS_PULL_REQUEST: ${TRAVIS_PULL_REQUEST:-false}"
echo "TRAVIS_TAG: ${TRAVIS_TAG:-}"
echo "TRAVIS_REPO_SLUG: ${TRAVIS_REPO_SLUG:-mdblp}"
echo "NO_DEFAULT_PACKAGING: ${NO_DEFAULT_PACKAGING:-false}"
echo "TRAVIS_PULL_REQUEST_SHA: ${TRAVIS_PULL_REQUEST_SHA}"

REPO_SLUG="${TRAVIS_REPO_SLUG:-mdblp}"
APP="${REPO_SLUG#*/}"
DOCKER_REPO="${APP}"

# If project has set BUILD_OPENAPI_DOC environment variable to true, then we build the openapi doc
function buildDocumentation {
    if [ "${BUILD_OPENAPI_DOC:-false}" = "true" ]; then
        echo "Build documentation"
        npm run build-doc
    fi
}

# If project has set BUILD_SOUP environment variable to true, then we build the SOUPs list
function buildSOUP {
    if [ "${BUILD_SOUP:-false}" = "true" ]; then
        echo "Build SOUPs list"
        npm run build-soup
    fi
}

# Build the archive .tar.gz
function buildArchive {
    if [ -n "${TRAVIS_TAG:-}" ]; then
        ARCHIVE_SRC_DIR='.'
        ARTIFACT_DIR='deploy'
        DO_BUILD='true'

        APP_DIR="${ARTIFACT_DIR}/${APP}"
        APP_TAG="${APP}-${TRAVIS_TAG}"

        TMP_DIR="/tmp/${APP}"

        # Reset the getopts counter
        OPTIND=1
        while getopts "d:n" option
        do
            case $option in
                d)
                    ARCHIVE_SRC_DIR="${OPTARG}"
                    ;;
                n)
                    DO_BUILD='false'
                    ;;
                \?)
                    echo "buildArchive(): Invalid option '${option}' at index ${OPTIND}, arg invalid: ${OPTARG}"
                    exit 2
                    ;;
            esac
        done

        if [ -f '.artifactignore' ]; then
            RSYNC_OPTIONS='--exclude-from=.artifactignore'
        else
            RSYNC_OPTIONS=''
        fi

        echo "Cleaning ${ARTIFACT_DIR} & ${TMP_DIR}"
        rm -rf "${ARTIFACT_DIR}" "${TMP_DIR}" || { echo 'ERROR: Unable to delete artifact and tmp directories'; exit 1; }
        mkdir -p -v "${APP_DIR}/" "${TMP_DIR}/" || { echo 'ERROR: Unable to create app and tmp directories'; exit 1; }

        if [ "${DO_BUILD}" == "true" ]; then
            echo "Building..."
            bash -eu build.sh || { echo 'ERROR: Unable to build project'; exit 1; }
        else
            echo "Skip building"
        fi

        echo "Sync ${ARCHIVE_SRC_DIR} to ${TMP_DIR}/${APP_TAG}/"
        rsync -a ${RSYNC_OPTIONS} "${ARCHIVE_SRC_DIR}" "${TMP_DIR}/${APP_TAG}/" || { echo 'ERROR: Unable to copy files'; exit 1; }

        echo "Building the archive ${APP_DIR}/${APP_TAG}.tar.gz"
        tar zcvf "${APP_DIR}/${APP_TAG}.tar.gz" -C "${TMP_DIR}" "${APP_TAG}" || { echo 'ERROR: Unable to create artifact'; exit 1; }

        echo "Cleaning ${TMP_DIR}"
        rm -rf "${TMP_DIR}"
    fi
}

# Build Docker image whatever
# Usage: buildDockerImage [-f <Dockerfile>] [-r <docker_repo>] [-t <docker_tag>] [-s <docker_scan_tag>] [-d <target_dir>]
function buildDockerImage {
    DOCKER_FILE='Dockerfile'
    DOCKER_TARGET_DIR='.'
    DOCKER_TAG=''

    # Reset the getopts counter
    OPTIND=1
    while getopts ":f:r:d:t:s:" option
    do
        case $option in
            f)
                DOCKER_FILE="${OPTARG}"
                ;;
            r)
                DOCKER_REPO="${OPTARG}"
                ;;
            d)
                DOCKER_TARGET_DIR="${OPTARG}"
                ;;
            t)
                DOCKER_TAG=":${OPTARG}"
                ;;
            s)
                DOCKER_SCAN_TAG=":${OPTARG}"
                ;;
            \?)
                echo "buildDockerImage(): Invalid option '${option}' at index ${OPTIND}, arg invalid: ${OPTARG}"
                exit 2
                ;;
        esac
    done

    echo "Building docker image ${DOCKER_REPO} using ${DOCKER_FILE} from ${DOCKER_TARGET_DIR}"
    docker build --tag "${DOCKER_REPO}" --build-arg npm_token="${NEXUS_TOKEN}" -f "${DOCKER_FILE}" "${DOCKER_TARGET_DIR}"

    # Security scan on the Operations registry
    # The security scan is executed only for a PR build
    # The image has to be pushed to Operations registry to benefit from their security scanner
    if [ ${SECURITY_SCAN:-true} = true ] && [ "$TRAVIS_PULL_REQUEST" != "false" ]; then
        echo "Security scan"
        local scanTag="${TRAVIS_PULL_REQUEST_SHA}-scanOnly"
        if [ ${OPS_DOCKER_REGISTRY:-""} != "" ]; then
            echo "Push image to Operations registry (${OPS_DOCKER_REGISTRY})"
            pushDocker ${OPS_DOCKER_REGISTRY} ${OPS_DOCKER_USERNAME} ${OPS_DOCKER_PASSWORD} ${DOCKER_REPO} ${scanTag}
            triggerSecurityScan ${DOCKER_REPO} ${scanTag}
        else
            echo "OPS Docker Registry unknown. Security Scan cannot occur."
            exit 1
        fi
    else
        echo "Skipping Security Scan"
    fi
}

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

# Publish docker image only when we have a tag.
# To avoid publishing 2x (on the branch build + PR) do not do it on the PR build.
function publishDockerImage {
    if [ -n "${TRAVIS_TAG:-}" -a "${TRAVIS_PULL_REQUEST:-false}" == "false" -a -n "${DOCKER_USERNAME:-}" -a -n "${DOCKER_PASSWORD:-}" ]; then
        echo "Docker push"
        # This line below removes "dblp." from the TRAVIS_TAG
        local image_version=${TRAVIS_TAG/dblp./}

        # We push to Default if the registry host is set
        if [ ${DOCKER_REGISTRY:-""} != "" ]; then
            echo "Push image to Default registry (${DOCKER_REGISTRY})"
            pushDocker ${DOCKER_REGISTRY} ${DOCKER_USERNAME} ${DOCKER_PASSWORD} ${DOCKER_REPO} ${image_version}
        else
            echo "Skipping docker push to Default registry"
        fi

        # We push to Operations if the registry host is set and if we don't have a tag for release candidate
        if [[ ${OPS_DOCKER_REGISTRY:-""} != "" && ! ${TRAVIS_TAG} =~ rc[0-9] ]]; then
            echo "Push image to Operations registry (${OPS_DOCKER_REGISTRY})"
            pushDocker ${OPS_DOCKER_REGISTRY} ${OPS_DOCKER_USERNAME} ${OPS_DOCKER_PASSWORD} ${DOCKER_REPO} ${image_version}
        else
            echo "Skipping push to Operations registry"
        fi
    else
        echo "Not a tag, not pushing the docker image"
    fi
}

# Default actions, if NO_DEFAULT_PACKAGING is not set or set to "false".
if [ -z "${NO_DEFAULT_PACKAGING:-}" -o "${NO_DEFAULT_PACKAGING}" = "false" ]; then
    echo "Default packaging"
    if [ "${TRAVIS_NODE_VERSION}" != "${ARTIFACT_NODE_VERSION}" ]; then
        echo "Unexpected node version: expected ${ARTIFACT_NODE_VERSION}, having ${TRAVIS_NODE_VERSION}"
        exit 0
    fi
    buildArchive
    buildDockerImage
    publishDockerImage
    buildDocumentation
    buildSOUP
else
    echo "Not using default packaging"
fi
