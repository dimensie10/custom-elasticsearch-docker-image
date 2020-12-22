#!/usr/bin/env bash

echo "defining TMPFILE.."
TMPFILE="/tmp/.$(basename "$0").$(date +"%Y%m%d%H%M%S.%N").tmp"
echo "defining INCLUDE_FILTER.."
INCLUDE_FILTER="${INCLUDE_FILTER:-$(cat include_filter.txt)}"
echo "defining EXCLUDE_FILTER.."
EXCLUDE_FILTER="${EXCLUDE_FILTER:-$(cat exclude_filter.txt)}"
echo "defining ARCHITECTURES.."
ARCHITECTURES="${ARCHITECTURES:-$(cat architectures.txt | perl -p -e 's#\n#,#;' | perl -p -e 's#,$##;')}"
echo "defining ARCHITECTURE_SUPPORT_REGEX.."
ARCHITECTURE_SUPPORT_REGEX="${ARCHITECTURE_SUPPORT_REGEX:-$(cat architecture_support_regex.txt)}"
echo "defining UPSTREAM_BASE_URL.."
export UPSTREAM_BASE_URL="docker.elastic.co/elasticsearch/elasticsearch"
echo "defining CUSTOM_BASE_URL.."
export CUSTOM_BASE_URL="docker.pkg.github.com/${GITHUB_REPOSITORY}/elasticsearch"
echo "defining ES_PLUGINS.."
export ES_PLUGINS="${ES_PLUGINS:-$(cat plugins.txt | perl -p -e 's#\n#,#;' | perl -p -e 's#,$##;')}"

function cleanup () {
    rm -f $TMPFILE ${TMPFILE}.stderr ${TMPFILE}.stdout ${TMPFILE}.stderr.* ${TMPFILE}.stdout.*
}

function is_debug_mode () {
    [ -n "$DEBUG" -a "$DEBUG" != "false" ]
}

function is_dryrun_mode () {
    [ -n "$DRYRUN" -a "$DRYRUN" = "true" ]
}

function dryrun_assume_existing () {
    [ -n "$DRYRUN_ASSUME_EXISTING" -a "$DRYRUN_ASSUME_EXISTING" = "true" ]
}

function execute_exclude_filter () {
    if [ "$EXCLUDE_FILTER" != "disabled" ]; then
        cat - | grep -v -E -e "${EXCLUDE_FILTER}"
    else
        cat -
    fi
}
export -f execute_exclude_filter

function execute_include_filter () {
    if [ "$INCLUDE_FILTER" != "disabled" ]; then
        cat - | grep -E -e "${INCLUDE_FILTER}"
    else
        cat -
    fi
}
export -f execute_include_filter

function get-all-tags-with-commits () {
    git ls-remote --refs --tags https://github.com/elastic/elasticsearch.git
    return 0
}

function get-all-tags () {
    get-all-tags-with-commits | awk '{ print $2; }'
    return 0
}

function convert-tags-to-versions () {
    get-all-tags | perl -p -e 's#refs/tags/v?##'
    return 0
}

function apply-include-filter-on-versions () {
    convert-tags-to-versions | execute_include_filter
    return 0
}

function get-elasticsearch-versions-to-process () {
    apply-include-filter-on-versions | execute_exclude_filter
    return 0
}

function multiply-by-architecture () {
    cat - | while read VERSION ; do
        for ARCHITECTURE in ${ARCHITECTURES//,/ } ; do
            if [ -n "$(echo "${VERSION}" | grep -E -e "${ARCHITECTURE_SUPPORT_REGEX}")" ] ; then
                echo "${VERSION}-${ARCHITECTURE}"
            elif [ -n "$(cat architectures.txt | grep -E -e "amd64")" ] ; then
                echo "$VERSION"
            fi ;
        done ;
    done
    return 0
}

function filter-out-already-existing-custom-es-docker-images () {
    if ! is_dryrun_mode ; then
        cat - | while read VERSIONARCH ; do
            TMPFILEERR="${TMPFILE}.stderr"
            TMPFILEOUT="${TMPFILE}.stdout"
            rm -f ${TMPFILEERR}
            curl --show-error -s -X GET https://docker.pkg.github.com/v2/${GITHUB_REPOSITORY}/elasticsearch/manifests/${VERSIONARCH} -u $GITHUB_ACTOR:$GITHUB_TOKEN 2>${TMPFILE}.stderr.curlerr | tee -a ${TMPFILE}.stdout.curl | jq '.errors | map(.code)[]' 1>$TMPFILEOUT 2>${TMPFILE}.stderr.jqerr
            if [ -n "$(cat ${TMPFILE}.stderr.curlerr)" ]; then
                echo "error: curl failed with error:" >${TMPFILEERR}
                cat "${TMPFILE}.stderr.curlerr" >>${TMPFILEERR}
            elif [ -n "$(cat ${TMPFILE}.stderr.jqerr)" ]; then
                echo "error: jq failed with error:" >${TMPFILEERR}
                cat "${TMPFILE}.stderr.jqerr" >>${TMPFILEERR}
                echo "curl output:" >>${TMPFILEERR}
                cat "${TMPFILE}.stdout.curl" >>${TMPFILEERR}
            elif [ -n "$(cat $TMPFILEOUT | grep -v -e MANIFEST_UNKNOWN -e NAME_UNKNOWN)" ]; then
                echo "error: unrecognized error code(s) detected: $(cat $TMPFILEOUT | grep -v -e MANIFEST_UNKNOWN -e NAME_UNKNOWN | sort | uniq | perl -p -e 's#\n#,#;' | perl -p -e 's#,$##;')" >${TMPFILEERR}
                echo "curl output:" >>${TMPFILEERR}
                cat "${TMPFILE}.stdout.curl" >>${TMPFILEERR}
            elif [ -n "$(cat $TMPFILEOUT)" ]; then
                echo ${VERSIONARCH}
            fi
            if [ -e $TMPFILEERR ]; then
                cat $TMPFILEERR >&2
                exit 1
            fi
            rm -f $TMPFILEERR $TMPFILEOUT ${TMPFILE}.stderr.* ${TMPFILE}.stdout.*
        done
    elif is_dryrun_mode && ! dryrun_assume_existing ; then
        cat -
    fi
    return 0
}

function dryrun-filter-out-already-existing-custom-es-docker-images () {
    if is_dryrun_mode ; then
        cat - | while read VERSIONARCH ; do
            echo "running 'curl -s -X GET https://docker.pkg.github.com/v2/${GITHUB_REPOSITORY}/elasticsearch/manifests/${VERSIONARCH} -u $GITHUB_ACTOR:$GITHUB_TOKEN | jq -r '.''.."
            curl -s -X GET https://docker.pkg.github.com/v2/${GITHUB_REPOSITORY}/elasticsearch/manifests/${VERSIONARCH} -u $GITHUB_ACTOR:$GITHUB_TOKEN | jq -r '.'
        done
    fi
    return 0
}

function publish-docker-image () {
    local ES_CUSTOM_IMAGE_URL="$1"
    export ES_UPSTREAM_IMAGE_URL="$2"
    local DRYRUN_ECHO=""
    echo "publishing ${ES_CUSTOM_IMAGE_URL} using FROM ${ES_UPSTREAM_IMAGE_URL}.."
    is_dryrun_mode && DRYRUN_ECHO="echo "
    echo "removing any existing Dockerfile.."
    rm -f Dockerfile
    echo "running '/opt/confd/bin/confd -onetime -confdir "." -backend env -config-file confd.toml'.."
    set -e
    /opt/confd/bin/confd -onetime -confdir "." -backend env -config-file confd.toml
    set +e
    echo "running 'docker build -t ${ES_CUSTOM_IMAGE_URL} .'.."
    set -e
    $DRYRUN_ECHO docker build -t $ES_CUSTOM_IMAGE_URL .
    set +e
    is_dryrun_mode && cat Dockerfile
    if is_dryrun_mode ; then
        echo docker login https://docker.pkg.github.com --username ${GITHUB_REPOSITORY_OWNER} --password-stdin
    else
        echo "running 'docker login https://docker.pkg.github.com --username ${GITHUB_REPOSITORY_OWNER} --password-stdin'.."
        set -e
        echo $GITHUB_TOKEN | docker login https://docker.pkg.github.com --username ${GITHUB_REPOSITORY_OWNER} --password-stdin
        set +e
    fi
    echo "running 'docker push $ES_CUSTOM_IMAGE_URL'.."
    set -e
    $DRYRUN_ECHO docker push $ES_CUSTOM_IMAGE_URL
    set +e
}

function publish-docker-images () {
    dryrun-filter-out-already-existing-custom-es-docker-images
    echo "running publish-docker-images.."
    cat - | while read VERSIONARCH ; do
        echo "running publish-docker-image for ${VERSIONARCH}.."
        publish-docker-image "${CUSTOM_BASE_URL}:${VERSIONARCH}" "${UPSTREAM_BASE_URL}:${VERSIONARCH}" ;
    done
    return 0
}

echo "checking if plugins are configured to be installed.."
if [ -z "${ES_PLUGINS}" ]; then
    echo "error: no plugins defined to install, exiting.."
    exit 1
fi

echo "checking if debug_mode is enabled.."
if is_debug_mode ; then
    echo "running debug_mode"
    case $DEBUG in
        step1) 
            echo "running get-all-tags-with-commits..";
            get-all-tags-with-commits;;
        step2) 
            echo "running get-all-tags..";
            get-all-tags;;
        step3) 
            echo "running convert-tags-to-versions..";
            convert-tags-to-versions;;
        step4) 
            echo "running apply-include-filter-on-versions..";
            apply-include-filter-on-versions;;
        step5) 
            echo "running get-elasticsearch-versions-to-process..";
            get-elasticsearch-versions-to-process;;
        step6) 
            echo "running get-elasticsearch-versions-to-process | multiply-by-architecture..";
            get-elasticsearch-versions-to-process | multiply-by-architecture;;
        step7) 
            echo "running get-elasticsearch-versions-to-process | multiply-by-architecture | filter-out-already-existing-custom-es-docker-images..";
            get-elasticsearch-versions-to-process | multiply-by-architecture | filter-out-already-existing-custom-es-docker-images;;
        *)
            echo "error: you must specify one of: [step1,step2,step3,step4,step5,step6,step7] for DEBUG environment variable. Exiting."
            exit 1;;
    esac
else
    echo "running get-elasticsearch-versions-to-process | multiply-by-architecture | filter-out-already-existing-custom-es-docker-images.."
    get-elasticsearch-versions-to-process |
        multiply-by-architecture |
        filter-out-already-existing-custom-es-docker-images |
        publish-docker-images
fi
