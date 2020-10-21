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
    # $1 name of the app
    local PARAM_APP_NAME=${1:-} 
    local DOCKER_CMD=""
    if [ -n "${PARAM_APP_NAME}" ]; then
        APP="${TRAVIS_REPO_SLUG#*/}-${PARAM_APP_NAME}"
        DOCKER_CMD="-f Dockerfile.${PARAM_APP_NAME}"
    else
        APP="${TRAVIS_REPO_SLUG#*/}"
    fi

    echo "Working on ${APP}"
    # Print some variables, so we can debug this script if something goes wrong
    echo "ARTIFACT_GO_VERSION: ${ARTIFACT_GO_VERSION}"
    echo "TRAVIS_GO_VERSION: ${TRAVIS_GO_VERSION}"
    echo "TRAVIS_BRANCH: ${TRAVIS_BRANCH}"
    echo "TRAVIS_PULL_REQUEST: ${TRAVIS_PULL_REQUEST}"
    echo "TRAVIS_TAG: ${TRAVIS_TAG}"
    echo "TRAVIS_REPO_SLUG: ${TRAVIS_REPO_SLUG}"
    echo "TRAVIS_PULL_REQUEST_SHA: ${TRAVIS_PULL_REQUEST_SHA}"

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

    if [ ${ARTIFACT_BUILD:-true} = true ]; then
        # Let's build
        ./build.sh || { echo 'ERROR: Unable to build project'; exit 1; }
        if [ -n "${TRAVIS_TAG:-}" -a ${ARTIFACT_DEPLOY:-true} = true ]; then
            # Prepare deployment artifacts
            ARTIFACT_DIR='deploy'

            APP_DIR="${ARTIFACT_DIR}/${APP}"
            APP_TAG="${APP}-${TRAVIS_TAG}"

            rm -rf "${ARTIFACT_DIR}/" || { echo 'ERROR: Unable to delete artifact directory'; exit 1; }
            mkdir -p "${APP_DIR}/" || { echo 'ERROR: Unable to create app directory'; exit 1; }

            mv dist "${APP_DIR}/${APP_TAG}" || { echo 'ERROR: Unable to move app artifact directory'; exit 1; }

            tar -c -z -f "${APP_DIR}/${APP_TAG}.tar.gz" -C "${APP_DIR}" "${APP_TAG}" || { echo 'ERROR: Unable to create artifact'; exit 1; }
        fi
    fi

    # Build Docker image whatever (failfast strategy)
    local docker_repo="${APP}"
    echo "Build Docker image ${docker_repo}"
    docker build --tag "${docker_repo}" ${DOCKER_CMD} .

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


# Test if any arguments
if [ $# == 0 ]; then 
    main
else
    for param in "$@"
    do
        case $param in
        service=*)
            SERVICE="${param#*=}"
            main $SERVICE
            shift
            ;;
        *)
            main
            ;;
        esac
    done
fi