Artifact Tools
=====
These scripts are here to build the artifacts of the YourLoops/BackLoops services: docker images, SOUP list, OpenAPI documentation...
Each service is in charge of using these scripts in their respective pipeline.
There are different versions:
- artifact_go.sh for projects written in GO (e.g. shoreline, hydrophone)
- artifact_node.sh for projects written in Node (e.g. gatekeeper, seagull)
- artifact_packaging.sh for Blip

In addition artifact_images.sh is here to download some images for Blip at build-time.
## artifact_go

This script is here to build the artifacts of the service: docker image, SOUP list and OpenAPI documentation

Add input parameters so that we can leverage it for platform-data service. below is an example that can be used to build and generate the docker images for platform-data.

- ARTIFACT_BUILD: default value is set to `true`. It triggers the execution of build.sh
- ARTIFACT_DEPLOY: default value is set to `true`. It triggers the deployment of binary files. Should be set to `false` soon. The `true` value is not compatible with platform project. 

```
export ARTIFACT_BUILD=true
export ARTIFACT_DEPLOY=false
./artifact_go.sh data
```
