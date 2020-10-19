Artifact Tools
=====

## artifact_go

Add input parameters so that we can leverage it for platform-data service. below is an example that can be used to build and generate the docker images for platform-data.

- ARTIFACT_BUILD: default value is set to `true`. It triggers the execution of build.sh
- ARTIFACT_DEPLOY: default value is set to `true`. It triggers the deployment of binary files. Should be set to `false` soon. The `true` value is not compatible with platform project. 

```
export ARTIFACT_BUILD=true
export ARTIFACT_DEPLOY=false
./artifact_go.sh data
```
