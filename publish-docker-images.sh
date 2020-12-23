#!/usr/bin/env bash

function cleanup () {
    rm -f $TMPFILE ${TMPFILE}.stderr ${TMPFILE}.stdout ${TMPFILE}.stderr.* ${TMPFILE}.stdout.*
}

function is_custom_base_url_overridden () {
    [ -n "$CUSTOM_BASE_URL_OVERRIDE" ]
}

function is_login_external () {
    [ -n "$EXTERNAL_LOGIN" -a "$EXTERNAL_LOGIN" = "true" ]
}

function use_amazon_ecr () {
    [ -n "$USE_AMAZON_ECR" -a "$USE_AMAZON_ECR" = "true" ]
}

function is_verbose_mode () {
    [ -n "$VERBOSE" -a "$VERBOSE" = "true" ]
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

function dryrun_enable_real_check () {
    [ -n "$DRYRUN_ENABLE_REAL_CHECK" -a "$DRYRUN_ENABLE_REAL_CHECK" = "true" ]
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

function check_github_packages () {
    local VERSIONARCH="$1"
    RETURNCODE="1"
    TMPFILEERR="${TMPFILE}.stderr"
    TMPFILEOUT="${TMPFILE}.stdout"
    rm -f $TMPFILEERR $TMPFILEOUT ${TMPFILE}.stderr.* ${TMPFILE}.stdout.*
    echo "running 'curl --show-error -s -X GET https://docker.pkg.github.com/v2/${GITHUB_REPOSITORY}/elasticsearch/manifests/${VERSIONARCH} -u $GITHUB_ACTOR:$GITHUB_TOKEN | tee -a ${TMPFILE}.stdout.curl | jq '(.errors // []) | map(.code)[]''.." >&4
    curl --show-error -s -X GET https://docker.pkg.github.com/v2/${GITHUB_REPOSITORY}/elasticsearch/manifests/${VERSIONARCH} -u $GITHUB_ACTOR:$GITHUB_TOKEN 2>${TMPFILE}.stderr.curlerr | tee -a ${TMPFILE}.stdout.curl | jq '(.errors // []) | map(.code)[]' 1>$TMPFILEOUT 2>${TMPFILE}.stderr.jqerr
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
        RETURNCODE="0"
    fi
    if [ -e $TMPFILEERR ]; then
        cat $TMPFILEERR >&2
        exit 1
    fi
    rm -f $TMPFILEERR $TMPFILEOUT ${TMPFILE}.stderr.* ${TMPFILE}.stdout.*
    return $RETURNCODE
}

function check_amazon_ecr () {
    local VERSIONARCH="$1"
    echo "running 'aws ecr describe-images --repository=${ECR_REPOSITORY_NAME:-elastic/elasticsearch} --image-ids=imageTag=${VERSIONARCH} 1>/dev/null 2>&1'.." >&4
    if aws ecr describe-images --repository=${ECR_REPOSITORY_NAME:-elastic/elasticsearch} --image-ids=imageTag=${VERSIONARCH} 1>/dev/null 2>&1 ; then
        return 1
    else
        return 0
    fi
}

function filter-out-already-existing-custom-es-docker-images () {
    if ! is_dryrun_mode ; then
        cat - | while read VERSIONARCH ; do
            if is_custom_base_url_overridden ; then
                custom_docker_image_existence_check ${VERSIONARCH} && echo ${VERSIONARCH}
            elif use_amazon_ecr ; then
                check_amazon_ecr ${VERSIONARCH} && echo ${VERSIONARCH}
            else
                check_github_packages ${VERSIONARCH} && echo ${VERSIONARCH}
            fi
        done
    elif is_dryrun_mode && ! dryrun_assume_existing ; then
        cat -
    fi
    return 0
}

function dryrun-filter-out-already-existing-custom-es-docker-images () {
    if is_dryrun_mode ; then
        cat - | while read VERSIONARCH ; do
            if is_custom_base_url_overridden ; then
                if dryrun_enable_real_check ; then
                    if custom_docker_image_existence_check ${VERSIONARCH} ; then
                        echo "dryrun_enable_real_check: image ${VERSIONARCH} does not exist"
                    else
                        echo "dryrun_enable_real_check: image ${VERSIONARCH} exists"
                    fi
                fi
                custom_docker_image_existence_check --dryrun ${VERSIONARCH}
            elif use_amazon_ecr ; then
                if dryrun_enable_real_check ; then
                    if check_amazon_ecr ${VERSIONARCH} ; then
                        echo "dryrun_enable_real_check: image ${VERSIONARCH} does not exist"
                    else
                        echo "dryrun_enable_real_check: image ${VERSIONARCH} exists"
                    fi
                fi
                echo "running 'aws ecr describe-images --repository=${ECR_REPOSITORY_NAME:-elastic/elasticsearch} --image-ids=imageTag=${VERSIONARCH} | jq -r '.''.." >&4
                aws ecr describe-images --repository=${ECR_REPOSITORY_NAME:-elastic/elasticsearch} --image-ids=imageTag=${VERSIONARCH} | jq -r '.'
                echo "running 'aws ecr describe-images --repository=${ECR_REPOSITORY_NAME:-elastic/elasticsearch} | jq -r '.''.." >&4
                aws ecr describe-images --repository=${ECR_REPOSITORY_NAME:-elastic/elasticsearch} | jq -r '.'
            else
                if dryrun_enable_real_check ; then
                    if check_github_packages ${VERSIONARCH} ; then
                        echo "dryrun_enable_real_check: image ${VERSIONARCH} does not exist"
                    else
                        echo "dryrun_enable_real_check: image ${VERSIONARCH} exists"
                    fi
                fi
                echo "running 'curl --show-error -s -X GET https://docker.pkg.github.com/v2/${GITHUB_REPOSITORY}/elasticsearch/manifests/${VERSIONARCH} -u $GITHUB_ACTOR:$GITHUB_TOKEN | jq -r '.''.." >&4
                curl --show-error -s -X GET https://docker.pkg.github.com/v2/${GITHUB_REPOSITORY}/elasticsearch/manifests/${VERSIONARCH} -u $GITHUB_ACTOR:$GITHUB_TOKEN | jq -r '.'
            fi
        done
    fi
    return 0
}

function publish-docker-image () {
    local ES_CUSTOM_IMAGE_URL="$1"
    export ES_UPSTREAM_IMAGE_URL="$2"
    local DRYRUN_ECHO=""
    echo "publishing ${ES_CUSTOM_IMAGE_URL} using FROM ${ES_UPSTREAM_IMAGE_URL}.." >&4

    is_dryrun_mode && DRYRUN_ECHO="echo "

    echo "removing any existing Dockerfile.." >&4
    rm -f Dockerfile

    echo "running '/opt/confd/bin/confd -onetime -confdir "." -backend env -config-file confd.toml'.." >&4
    /opt/confd/bin/confd -onetime -confdir "." -backend env -config-file confd.toml || exit 1
    is_dryrun_mode && cat Dockerfile

    echo "running 'docker build -t ${ES_CUSTOM_IMAGE_URL} .'.." >&4
    if ! $DRYRUN_ECHO docker build -t $ES_CUSTOM_IMAGE_URL . ; then
        echo "error: running 'docker build -t ${ES_CUSTOM_IMAGE_URL} .' failed. Dockerfile contents:" >&2
        cat Dockerfile >&2
        exit 1
    fi

    if ! is_login_external ; then
        if is_custom_base_url_overridden ; then
            if is_dryrun_mode ; then
                custom_docker_registry_login --dryrun ${VERSIONARCH}
            else
                custom_docker_registry_login ${VERSIONARCH}
            fi
        elif use_amazon_ecr ; then
            if is_dryrun_mode ; then
                echo "aws ecr get-login-password --region eu-west-1 | docker login --username AWS --password-stdin ${ECR_AWS_ACCOUNT_ID}.dkr.ecr.${ECR_AWS_REGION:-eu-west-1}.amazonaws.com"
            else
                echo "running 'aws ecr get-login-password --region eu-west-1 | docker login --username AWS --password-stdin ${ECR_AWS_ACCOUNT_ID}.dkr.ecr.${ECR_AWS_REGION:-eu-west-1}.amazonaws.com'.." >&4
                aws ecr get-login-password --region eu-west-1 | docker login --username AWS --password-stdin ${ECR_AWS_ACCOUNT_ID}.dkr.ecr.${ECR_AWS_REGION:-eu-west-1}.amazonaws.com
            fi
        else
            if is_dryrun_mode ; then
                echo docker login https://docker.pkg.github.com --username ${GITHUB_REPOSITORY_OWNER} --password-stdin
            else
                echo "running 'docker login https://docker.pkg.github.com --username ${GITHUB_REPOSITORY_OWNER} --password-stdin'.." >&4
                echo $GITHUB_TOKEN | docker login https://docker.pkg.github.com --username ${GITHUB_REPOSITORY_OWNER} --password-stdin || exit 1
            fi
        fi
    fi

    echo "running 'docker push $ES_CUSTOM_IMAGE_URL'.." >&4
    $DRYRUN_ECHO docker push $ES_CUSTOM_IMAGE_URL || exit 1
}

function publish-docker-images () {
    dryrun-filter-out-already-existing-custom-es-docker-images
    echo "running publish-docker-images.." >&4
    cat - | while read VERSIONARCH ; do
        echo "running publish-docker-image for ${VERSIONARCH}.." >&4
        publish-docker-image "${CUSTOM_BASE_URL}:${VERSIONARCH}" "${UPSTREAM_BASE_URL}:${VERSIONARCH}" ;
    done
    return 0
}

if is_verbose_mode ; then
    exec 4>&2
else
    exec 4>/dev/null
fi

echo "defining TMPFILE.." >&4
TMPFILE="/tmp/.$(basename "$0").$(date +"%Y%m%d%H%M%S.%N").tmp"
echo "defining INCLUDE_FILTER.." >&4
INCLUDE_FILTER="${INCLUDE_FILTER:-$(cat include_filter.txt)}"
echo "defining EXCLUDE_FILTER.." >&4
EXCLUDE_FILTER="${EXCLUDE_FILTER:-$(cat exclude_filter.txt)}"
echo "defining ARCHITECTURES.." >&4
ARCHITECTURES="${ARCHITECTURES:-$(cat architectures.txt | perl -p -e 's#\n#,#;' | perl -p -e 's#,$##;')}"
echo "defining ARCHITECTURE_SUPPORT_REGEX.." >&4
ARCHITECTURE_SUPPORT_REGEX="${ARCHITECTURE_SUPPORT_REGEX:-$(cat architecture_support_regex.txt)}"
echo "defining UPSTREAM_BASE_URL.." >&4
export UPSTREAM_BASE_URL="docker.elastic.co/elasticsearch/elasticsearch"
echo "defining CUSTOM_BASE_URL.." >&4
if is_custom_base_url_overridden ; then
    export CUSTOM_BASE_URL="$CUSTOM_BASE_URL_OVERRIDE"
elif use_amazon_ecr ; then
    export CUSTOM_BASE_URL="${ECR_AWS_ACCOUNT_ID}.dkr.ecr.${ECR_AWS_REGION:-eu-west-1}.amazonaws.com/${ECR_REPOSITORY_NAME:-elastic/elasticsearch}"
else
    export CUSTOM_BASE_URL="docker.pkg.github.com/${GITHUB_REPOSITORY}/elasticsearch"
fi
echo "defining ES_PLUGINS.." >&4
export ES_PLUGINS="${ES_PLUGINS:-$(cat plugins.txt | perl -p -e 's#\n#,#;' | perl -p -e 's#,$##;')}"

if is_custom_base_url_overridden ; then
    echo "checking if necessary custom functions are defined.." >&4
    if ! type custom_docker_registry_login &>/dev/null ; then
        echo "error: custom function 'custom_docker_registry_login' is not defined, exiting.." >&2
        exit 1
    fi
    if ! type custom_docker_image_existence_check &>/dev/null ; then
        echo "error: custom function 'custom_docker_image_existence_check' is not defined, exiting.." >&2
        exit 1
    fi
fi

echo "checking if plugins are configured to be installed.." >&4
if [ -z "${ES_PLUGINS}" ]; then
    echo "error: no plugins defined to install, exiting.." >&2
    exit 1
fi

echo "checking if debug_mode is enabled.." >&4
if is_debug_mode ; then
    echo "running debug_mode" >&4
    case $DEBUG in
        step1) 
            echo "running get-all-tags-with-commits.." >&4;
            get-all-tags-with-commits;;
        step2) 
            echo "running get-all-tags.." >&4;
            get-all-tags;;
        step3) 
            echo "running convert-tags-to-versions.." >&4;
            convert-tags-to-versions;;
        step4) 
            echo "running apply-include-filter-on-versions.." >&4;
            apply-include-filter-on-versions;;
        step5) 
            echo "running get-elasticsearch-versions-to-process.." >&4;
            get-elasticsearch-versions-to-process;;
        step6) 
            echo "running get-elasticsearch-versions-to-process | multiply-by-architecture.." >&4;
            get-elasticsearch-versions-to-process | multiply-by-architecture;;
        step7) 
            echo "running get-elasticsearch-versions-to-process | multiply-by-architecture | filter-out-already-existing-custom-es-docker-images.." >&4;
            get-elasticsearch-versions-to-process | multiply-by-architecture | filter-out-already-existing-custom-es-docker-images;;
        *)
            echo "error: you must specify one of: [step1,step2,step3,step4,step5,step6,step7] for DEBUG environment variable. Exiting." >&2
            exit 1;;
    esac
else
    echo "running get-elasticsearch-versions-to-process | multiply-by-architecture | filter-out-already-existing-custom-es-docker-images.." >&4
    get-elasticsearch-versions-to-process |
        multiply-by-architecture |
        filter-out-already-existing-custom-es-docker-images |
        publish-docker-images
fi
