# Custom Elasticsearch Docker Image

## Overview

This repository is intended to be forked. It was created to ease the creation of custom Elasticsearch docker images, specifically for the installation of plugins. It by default uses Github Actions to automate extending Elasticsearch docker images with a configured set of plugins for a configured set of versions and architectures, and pushes the docker images by default to Github Packages. This way, nothing needs to happen locally, and no dedicated infrastructure is needed for this process.

Alternatively (if you're using Kubernetes for example), you could also use init containers to achieve the same, see: https://www.elastic.co/guide/en/cloud-on-k8s/current/k8s-init-containers-plugin-downloads.html. This however will make your deployment process slower and introduce a live dependency on the plugins repository each (random) time an Elasticsearch k8s pod gets restarted.

Note: pre-7.8.0, architectures are not taken into account, since for those versions Elastic hasn't published architecture specific images. If this repository is configured to handle any architecture except amd64, it will automatically not build any version pre-7.8.0.

## Supported Docker Registries

Currently, the supported docker registries are:

* Github Packages (`docker.pkg.github.com`)
* Amazon ECR (requires configuration of extra environment variables)
* Private docker registries (requires configuration of extra environment variables as well as 2 externally defined bash functions)

## Pull Requests

Pull requests are accepted for supporting more types of (cloud) docker registries as well as CI systems (for example gitlab workflow, Jenkins pipeline).

## How It Works

On each push to master, it:

* installs ConfD
* publishes docker images, which consists of these steps:
  * get versions of elasticsearch to process, which is comprised of these sub steps:
    * step 1: use `git ls-remote` to get all tags from the elasticsearch github repository
    * step 2: grab only column 2 (tags, not the commits) from the previous step
    * step 3: grab output of previous steps and strip off `refs/tags/v` from the start of each tag
    * step 4: filter the list according to `INCLUDE_FILTER`
    * step 5: filter the list according to `EXCLUDE_FILTER`
  * multiply the list of versions to be processed by the chosen architectures (step 6)
  * filter out any version-architecture combinations for which a docker image already exists in the docker registry (step 7)
  * build and publish the docker images (for each version-architecture combination chosen), which is comprised of these sub steps:
    * use ConfD to generate the appropriate Dockerfile from `templates/Dockerfile.tmpl` based on the chosen plugins and appropriate `FROM`
    * build the docker image with the correct tag
    * login to docker registry
    * push the docker image

## Usage

### Tips

* Fork the repository
* Make configuration changes in the files using the editor inside github (in the browser), so that you don't have to clone the files locally
* Add a schedule to the workflow, so it for example runs at 3 am and it will automatically make new docker images nightly in sync with releases of Elasticsearch

### Defaults

Environment variable | Default | Source
-------------------- | ------- | ------
`INCLUDE_FILTER` | `^.*$` | `include_filter.txt` (can be overridden with `secrets.INCLUDE_FILTER`)
`EXCLUDE_FILTER` | `^.*$ `| `exclude_filter.txt` (can be overridden with `secrets.EXCLUDE_FILTER`)
`ARCHITECTURES` | `amd64` | `architectures.txt` (can be overridden with `secrets.ARCHITECTURES)`
`ES_PLUGINS` | *undefined* | `plugins.txt` (can be overridden with `secrets.ES_PLUGINS`)
`DEBUG` | *undefined* | `secrets.DEBUG`
`DRYRUN` | *undefined* | `secrets.DRYRUN`
`DRYRUN_ASSUME_EXISTING` | *undefined* | `secrets.DRYRUN_ASSUME_EXISTING`
`DRYRUN_ENABLE_REAL_CHECK` | *undefined* | `secrets.DRYRUN_ENABLE_REAL_CHECK`
`VERBOSE` | *undefined* | `secrets.VERBOSE`
`CUSTOM_BASE_URL_OVERRIDE` | *undefined* | `secrets.CUSTOM_BASE_URL_OVERRIDE`
`EXTERNAL_LOGIN` | *undefined* | `secrets.EXTERNAL_LOGIN`
`AWS_ACCESS_KEY_ID` | *undefined* | `secrets.AWS_ACCESS_KEY_ID`
`AWS_SECRET_ACCESS_KEY` | *undefined* | `secrets.AWS_SECRET_ACCESS_KEY`
`ECR_AWS_ACCOUNT_ID` | *undefined* | `secrets.ECR_AWS_ACCOUNT_ID`
`ECR_AWS_REGION` | `eu-west-1` | `secrets.ECR_AWS_REGION`
`ECR_REPOSITORY_NAME` | `elastic/elasticsearch` | `secrets.ECR_REPOSITORY_NAME`
`USE_AMAZON_ECR` | *undefined* | `secrets.USE_AMAZON_ECR`

### Configuration

Configuration happens through text files and/or Github Secrets for setting environment variables. In case you want to deliver the environment variables in a different way than using Secrets, adapt the Github Workflow.

#### External login to docker registry

If you want to handle logging in to the docker registry by yourself before this script is called, set

```
EXTERNAL_LOGIN=true
```

as Github Secret. This disables logging into the docker registry in publish-docker-images.sh, irrespective of which type of docker registry is used.

#### Use Amazon ECR

If you want to push the docker images to Amazon ECR, you will have to define a number of Github Secrets, as shown in the below table (all except ECR_AWS_REGION and ECR_REPOSITORY_NAME are required). 

Secret name | Example value
----------- | -------------
AWS_ACCESS_KEY_ID | ABCDEFGHIJ1234567890
AWS_SECRET_ACCESS_KEY | abcdefghijkl/+ABCDEFGHIJKL/+1234567890/+
ECR_AWS_ACCOUNT_ID | 123456789012
USE_AMAZON_ECR | true
ECR_AWS_REGION | eu-west-1
ECR_REPOSITORY_NAME | elastic/elasticsearch

#### Use private docker registry

If you want to push to any another docker registry, you will need to configure:

```
CUSTOM_BASE_URL_OVERRIDE=<imagename>
```

where `<imagename>` is as defined [here](https://docs.docker.com/engine/reference/commandline/tag/) (`An image name is made up of slash-separated name components, optionally prefixed by a registry hostname.`); it should thus exclude the image tag and separating colon.

Additionally, two bash functions need to be defined externally and exported:

```
funcion custom_docker_registry_login () {
    ...
}
```

```
funcion custom_docker_image_existence_check () {
    ...
}
```

The functions should accept a `--dryrun` argument, which should cause the function to only output the command which would be executed normally. The functions should output error output to stderr and output normal output to stdout.

Furthermore, `custom_docker_image_existence_check` should accept an argument that states the version-architecture combination that should be checked. It should return a returncode of 0 if the docker image does not exist yet and a returncode higher than 0 if the docker image already exists.

#### Versions To Build

Versions can be selected using an include filter and exclude filter, which are implemented by regular expressions. By default all versions are first included and then excluded (they are both set to `^.*$`), in order to prevent Github Actions to immediately start building after forking this repository.

The filters can be configured in `include_filter.txt` and `exclude_filter.txt`, which should have one regular expression on the first line only.

Suppose you only want to build from version 7 onwards, but want to exclude alphas, betas and release candidates:

`include_filter.txt`:
```
^([7-9]|[1-9]\d+)\.\d+\.\d+
```

`exclude_filter.txt`:
```
-(alpha|beta|rc)\d+$
```

Alternatively, `INCLUDE_FILTER` and `EXCLUDE_FILTER` can be delivered using Github Secrets, for example for debugging purposes.

#### Plugins To Install

Plugins can be configured in `plugins.txt`. By default no plugins are installed, and therefore no docker images are built. `plugins.txt` should contain one plugin name or zip URL per line, for example:

```
repository-s3
mapper-size
analysis-icu
mapper-annotated-text
https://d3g5vo6xdbdb9a.cloudfront.net/downloads/elasticsearch-plugins/opendistro-security/opendistro_security-1.12.0.0.zip
```

Alternatively, `ES_PLUGINS` Github Secret can contain a comma separated (without spaces) list of plugins to install.

#### Architectures To Build For

Architectures can be configured in `architectures.txt`, one per line. By default only `amd64` is built for. This can also be specified using the `ARCHITECTURES` Github Secret, comma separated without spaces.

## Debugging

### Verbose Mode

You can enable verbose mode by setting:

```
VERBOSE=true
```

as a Github Secret. It will communicate about the various commands it's executing.

### Debug Mode

You can enable debug mode, which will only output the filtering of the versions. Any of the steps mentioned above can be debugged, for example:

```
DEBUG=step3
```

Make sure there's no space between step and the number of the step. This needs to be supplied using a Github Secret.

### Dry Run Mode

You can enable dry run mode by setting:

```
DRYRUN=true
```

as a Github Secret. Versions will be fetched and filtered, but these steps will show the commands that would be executed, instead of executing them:

* `docker build`
* `docker login`
* `docker push`

It will also show the `Dockerfile` that was generated. By default it will assume the docker image doesn't exist in the docker registry. To make the script assume it does, set this:

```
DRYRUN_ASSUME_EXISTING=true
```

While doing a dryrun, you can enable actual checking of existence of the docker images by setting:

```
DRYRUN_ENABLE_REAL_CHECK=true
```