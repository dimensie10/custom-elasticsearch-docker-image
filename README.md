# Custom Elasticsearch Docker Image

## Overview

This repository is intended to be forked. It was created to ease the creation of custom Elasticsearch docker images, specifically for the installation of plugins. It uses Github Actions to automate extending Elasticsearch docker images with a configured set of plugins for a configured set of versions and architectures, and pushes the docker images to Github Packages. This way, nothing needs to happen locally, or on dedicated infrastructure for this process.

Note: pre-7.8.0, architectures are not taken into account, since for those versions Elasticsearch hasn't published architecture specific images. If this repository is configured to handle any architecture except amd64, it will automatically not build any version pre-7.8.0.

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
  * filter out any version-architecture combinations for which a docker image already exists in the Github Packages repository (step 7)
  * build and publish the docker images (for each version-architecture combination chosen), which is comprised of these sub steps:
    * use ConfD to generate the appropriate Dockerfile from `templates/Dockerfile.tmpl` based on the chosen plugins and appropriate `FROM`
    * build the docker image with the correct tag
    * login to *docker.pkg.github.com*
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

### Configuration

#### Versions To Build

Versions can be selected using an include filter and exclude filter, which are implemented with a regular expression. By default all versions are first included and then excluded (they are both set to `^.*$`), in order to prevent Github Actions to immediately start building after forking this repository.

The filters can be configured in `include_filter.txt` and `exclude_filter.txt`, which should have regular expression on the first line and nothing else.

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

Plugins can be configured in `plugins.txt`, by default no plugins are installed, and therefore no docker images are built. `plugins.txt` should contain one plugin name or zip URL per line, for example:

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

### Debug Mode

You can enable debug mode, which will only output the filtering of the versions. Any of the steps mentioned above can be debugged, for example:

```
DEBUG=step3
```

Make sure there's no space between step and the number of the step. This needs to be supplied using a Github Secret (or adapt the Github Workflow).

### Dry Run Mode

You can enable dry run mode by setting:

```
DRYRUN=true
```

as a Github Secret. Versions will be fetched and filtered, but these steps will show the commands that would be executed, instead of executing them:

* `docker build`
* `docker login`
* `docker push`

It will also show the `Dockerfile` that was generated. By default it will assume the docker image doesn't exist in the Github Packages docker repo. To make the script assume it does, set this:

```
DRYRUN_ASSUME_EXISTING=true
```