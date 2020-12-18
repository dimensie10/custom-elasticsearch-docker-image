#!/usr/bin/env bash

INCLUDE_FILTER="${INCLUDE_FILTER:-$(cat include_filter.txt)}"
EXCLUDE_FILTER="${EXCLUDE_FILTER:-$(cat exclude_filter.txt)}"
ARCHITECTURES="${ARCHITECTURES:-$(cat architectures.txt | perl -p -e 's#\n#,#;' | perl -p -e 's#,$##;')}"
export UPSTREAM_BASE_URL="docker.elastic.co/elasticsearch/elasticsearch"
export CUSTOM_BASE_URL="docker.pkg.github.com/${GITHUB_REPOSITORY}/elasticsearch"
export ES_PLUGINS="${ES_PLUGINS:-$(cat plugins.txt | perl -p -e 's#\n#,#;' | perl -p -e 's#,$##;')}"

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
            echo $VERSION $ARCHITECTURE ;
        done ;
    done
    return 0
}

function filter-out-already-existing-custom-es-docker-images () {
    if ! is_dryrun_mode ; then
        cat - | while read VERSION ARCH ; do
            if [ -n "$(curl -s -X GET https://docker.pkg.github.com/v2/${GITHUB_REPOSITORY}/elasticsearch/manifests/${VERSION}-${ARCH} -u $GITHUB_ACTOR:$GITHUB_TOKEN | jq '.errors | map(.code)[]' 2>/dev/null | grep MANIFEST_UNKNOWN 2>/dev/null)" ] ; then
                echo ${VERSION} ${ARCH}
            fi ;
        done
    elif is_dryrun_mode && ! dryrun_assume_existing ; then
        cat -
    fi
    return 0
}

function publish-docker-image () {
    local VERSION="$1"
    local ARCH="$2"
    local ES_CUSTOM_IMAGE_URL="$3"
    export ES_UPSTREAM_IMAGE_URL="$4"
    local DRYRUN_ECHO=""
    is_dryrun_mode && DRYRUN_ECHO="echo "
    rm -f Dockerfile
    set -e
    /opt/confd/bin/confd -onetime -confdir "." -backend env -config-file confd.toml
    $DRYRUN_ECHO docker build -t $ES_CUSTOM_IMAGE_URL .
    set +e
    is_dryrun_mode && cat Dockerfile
    if is_dryrun_mode ; then
        set -e
        echo docker login https://docker.pkg.github.com --username ${GITHUB_REPOSITORY_OWNER} --password-stdin
        set +e
    else
        echo $GITHUB_TOKEN | docker login https://docker.pkg.github.com --username ${GITHUB_REPOSITORY_OWNER} --password-stdin
    fi
    set -e
    $DRYRUN_ECHO docker push $ES_CUSTOM_IMAGE_URL
    set +e
}

function publish-docker-images () {
    cat - | while read VERSION ARCH ; do
        publish-docker-image $VERSION $ARCH "${CUSTOM_BASE_URL}:${VERSION}-${ARCH}" "${UPSTREAM_BASE_URL}:${VERSION}-${ARCH}" ;
    done
    return 0
}

if [ -z "${ES_PLUGINS}" ]; then
    echo "error: no plugins defined to install, exiting.."
    exit 1
fi

if is_debug_mode ; then
    case $DEBUG in
        step1) 
            get-all-tags-with-commits;;
        step2) 
            get-all-tags;;
        step3) 
            convert-tags-to-versions;;
        step4) 
            apply-include-filter-on-versions;;
        step5) 
            get-elasticsearch-versions-to-process;;
        step6) 
            get-elasticsearch-versions-to-process | multiply-by-architecture;;
        step7) 
            get-elasticsearch-versions-to-process | multiply-by-architecture | filter-out-already-existing-custom-es-docker-images;;
        *)
            echo "error: you must specify one of: [step1,step2,step3,step4,step5,step6,step7] for DEBUG environment variable. Exiting."
            exit 1;;
    esac
else
    get-elasticsearch-versions-to-process |
        multiply-by-architecture |
        filter-out-already-existing-custom-es-docker-images |
        publish-docker-images
fi
