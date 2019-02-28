#!/bin/bash

set -eo pipefail

export POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-mysecretpassword}"
export ANCHORE_DB_PASSWORD="$POSTGRES_PASSWORD"
export ANCHORE_DB_USER="$POSTGRES_USER"
export ANCHORE_DB_NAME="$POSTGRES_DB"
export ANCHORE_DB_HOST="$ANCHORE_ENDPOINT_HOSTNAME"
export ANCHORE_HOST_ID="$ANCHORE_ENDPOINT_HOSTNAME"
export ANCHORE_CLI_URL="http://${ANCHORE_ENDPOINT_HOSTNAME}:8228/v1"

display_usage() {
cat << EOF

  For performing vulnerability analysis on local docker images, utilizing Anchore Engine in stateless mode.
  
  Usage: ${0##*/} [ -d Dockerfile ] [ -p policy.json ] [ -i IMAGE_ONE ] [ -f ]

      -d  Dockerfile path (optional)
      -p  Anchore policy bundle path (optional)
      -i  Pass an image name
      -f  Fail script upon failed policy evaluation
 
EOF
}

error() {
    ret="$?"
    printf '\n\n%s\n\n' "ERROR - $0 received SIGTERM or SIGINT"
    # kill anchore_ci_tools.py script while it's in a wait loop
    pkill -f python3 &> /dev/null
    exit "$ret"
}

trap 'error' SIGTERM SIGINT

# Parse options
while getopts ':d:p:i:fh' option; do
  case "${option}" in
    d  ) d_flag=true; dockerfile="/anchore-engine/$(basename $OPTARG)";;
    p  ) p_flag=true; policy_bundle="/anchore-engine/$(basename $OPTARG)";;
    i  ) i_flag=true; image_name="${OPTARG}";;
    f  ) f_flag=true;;
    h  ) display_usage >&2; exit;;
  esac
done

shift "$((OPTIND - 1))"

if [[ "$d_flag" ]] && [[ -z "$i_flag" ]]; then
    printf '\n\t\n\n' "ERROR - must specify an image when passing a Dockerfile."
    exit 1
fi

if [[ "$i_flag" ]]; then
    if [[ "$image_name" =~ (.*/|)(.+):(.+) ]]; then
        file_name="/anchore-engine/${BASH_REMATCH[2]}+${BASH_REMATCH[3]}.tar"
        if [[ ! -f "$file_name" ]]; then
            cat <&0 > "$file_name"
        fi
    else
        printf '\n%s\n\n' "ERROR - invalid docker image name passed with -i option."
    fi
fi

start_services() {
    export PATH=$PATH:/usr/lib/postgresql/9.6/bin/
    echo "127.0.0.1 $ANCHORE_ENDPOINT_HOSTNAME" >> /etc/hosts
    echo "Starting Anchore Engine."
    nohup anchore-manager service start --all &> /var/log/anchore.log &
    echo "Starting Postgresql."
    touch /var/log/postgres.log && chown postgres:postgres /var/log/postgres.log
    # TODO - not sure if we actually need gosu - ubuntu may include su by default
    nohup gosu postgres bash -c 'postgres &> /var/log/postgres.log &' &> /dev/null
    sleep 3 && gosu postgres pg_isready -d postgres --quiet && echo "Postgresql started successfully!"
    echo "Starting Docker registry."
    nohup registry serve /etc/docker/registry/config.yml &> /var/log/registry.log &
    curl --silent --retry 3 --retry-connrefused "${ANCHORE_ENDPOINT_HOSTNAME}:5000" && echo "Docker registry started successfully!"
}

prepare_image() {
    #anchore-cli system wait --feedsready "vulnerabilities,nvd" && printf '\n%s\n' "Anchore Engine started successfully!"
    echo "Waiting for Anchore Engine to be available."
    # pass python script to background process & wait, required to handle keyboard interrupt when running container non-interactively.
    anchore_ci_tools.py --wait &
    declare wait_proc="$!"
    wait "$wait_proc"
    printf '%s\n' "Searching for Docker archive files in /anchore-engine."
    scan_files=()
    # policy_bundle_array=()
    # dockerfile_array=()
    for i in $(find /anchore-engine -type f); do
        if [[ $(skopeo inspect "docker-archive:${i}") ]] && [[ ! "${scan_files[@]}" =~ "$i" ]]; then 
            scan_files+=("$i")
            echo "Found docker archive: $i"
        else 
            echo "Ignoring invalid docker archive: $i"
            # TODO - handle multiple dockerfiles & policy bundles
            # shopt -s nocasematch
            # if [[ "$i" =~ .*dockerfile*. ]]; then
            #     dockerfile_array+=("$i")
            # elif [[ "$i" =~ .*policy*. ]]; then
            #     policy_bundle_array+=("$i")
            # fi
            # shopt -u nocasematch
        fi
    done
}

start_scan() {
    if [[ "${#scan_files[@]}" -gt 0 ]]; then
        for i in "${scan_files[@]}"; do
            printf '\n%s\n' "Adding image to Anchore Engine: $i"
            anchore_analysis "$i"
        done
    else
        printf '\n%s\n\n' "ERROR - No valid docker archives provided."
        exit 1
    fi
}

anchore_analysis() {
    if [[ -z "$image_name" ]]; then
        image_repo="$(basename ${1%.*})"
        image_tag="analyzed"
    else
        image_repo="${image_name%:*}"
        image_tag="${image_name#*:}" 
    fi
    anchore_image_name="${ANCHORE_ENDPOINT_HOSTNAME}:5000/${image_repo}:${image_tag}"
    skopeo copy --dest-tls-verify=false "docker-archive:${1}" "docker://${anchore_image_name}"
    echo
    if [[ "$d_flag" ]] && [[ -f "$dockerfile" ]]; then
        anchore-cli image add "$anchore_image_name" --dockerfile "$dockerfile"
    else
        anchore-cli image add "$anchore_image_name"
    fi
    # pass python script to background process & wait, required to handle keyboard interrupt when running container non-interactively.
    anchore_ci_tools.py --wait --image "$anchore_image_name" &
    declare wait_proc="$!"
    wait "$wait_proc"
    if [[ "$p_flag" ]]; then
        (anchore-cli --json policy add "$policy_bundle" | jq '.policyId' | xargs anchore-cli policy activate) || \
            printf "\n%s\n" "Unable to activate policy bundle - $policy_bundle - using default policy bundle."
    fi
    if [[ "$f_flag" ]]; then
        anchore-cli evaluate check $anchore_image_name --detail
    else
        (set +o pipefail; anchore-cli evaluate check $anchore_image_name --detail | tee /dev/null)
    fi
    anchore_ci_tools.py -r --image "$anchore_image_name"
}

if [[ "${#@}" -ne 0 ]]; then
    # use 'debug' as the first input param for script. This starts all services, then execs all proceeding inputs
    if [[ "$1" = 'debug' ]]; then
        start_services
        exec "${@:2}"
    else
        exec "$@"
    fi
fi

start_services
prepare_image
start_scan