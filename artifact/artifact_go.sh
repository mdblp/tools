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
    printenv
}

main
