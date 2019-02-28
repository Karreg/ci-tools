#!/bin/bash

set -e

# If using a locally built stateless CI container, export ANCHORE_CI_IMAGE=<image_name>. 
# This will override the image name from Dockerhub.
stateless_anchore_image="${ANCHORE_CI_IMAGE:-docker.io/anchore/private_testing:stateless_ci}"

display_usage() {
cat << EOF

  For performing vulnerability analysis on local docker images, utilizing Anchore Engine in stateless mode.
  
  Usage: ${0##*/} [ -d ./Dockerfile ] [ -p ./policy.json ] [ IMAGE_ONE ] [ IMAGE_TWO ... ]

      -d  Dockerfile path (optional)
      -p  Anchore policy bundle path (optional)
      -f  Fail script up failed Anchore policy evaluation
 
EOF
}

cleanup() {
    ret="$?"
    set +e
    if [[ -z "$docker_id" ]]; then
        declare docker_id="${docker_name:-$(docker ps -a | grep 'stateless-anchore-engine' | awk '{print $1}')}"
    fi
    if [[ ! -z "$docker_id" ]]; then
        for i in $docker_id; do
            printf '\n%s\n' "Cleaning up docker container: $docker_id"
            docker kill "$i" &> /dev/null
            docker rm "$i" &> /dev/null
            sleep 5
            unset docker_id
        done
    fi
    if [[ -f "/tmp/${file_name}" ]]; then
        rm "/tmp/${file_name}"
    fi
    set -e
    exit "$ret"
}

trap 'cleanup' EXIT SIGTERM SIGINT

# Parse options
while getopts ':d:p:fh' option; do
  case "$option" in
    h  ) display_usage >&2; exit;;
    d  ) d_flag=true; dockerfile="$OPTARG";;
    f  ) f_flag=true;;
    p  ) p_flag=true; policy_bundle="$OPTARG";;
    \? ) printf "\n\t%s\n\n" "  Invalid option: -${OPTARG}"; display_usage >&2; exit 1;;
    :  ) printf "\n\t%s\n\n%s\n\n" "  Option -${OPTARG} requires an argument."; display_usage >&2; exit 1;;
  esac
done

shift "$((OPTIND - 1))"

if [[ ! $(which docker) ]]; then
    printf '\n\t%s\n\n' 'ERROR - Docker is not installed or cannot be found in $PATH.'
    exit 1
elif [[ "${#@}" -eq 0 ]]; then
    printf '\n\t%s\n\n' "ERROR - $0 requires at least 1 image name as input."
    display_usage
    exit 1
elif [[ "$d_flag" ]] && [[ "${#@}" -gt 1 ]]; then
    printf '\n\t%s\n\n' 'ERROR - If specifying a Dockerfile, only 1 image can be scanned at a time.'
    display_usage
    exit 1
fi

image_names=()
failed_images=()
scan_images=()

for i in "$@"; do
    if [[ "$i" =~ [a-zA-Z0-9/_.-]+:[a-zA-Z0-9_-]+ ]]; then
        if [[ ! "${image_names[@]}" =~ "$i" ]]; then
            image_names+=("$i")
        fi
    else
        printf '\n\t%s\n\n' "ERROR - not a valid docker image name: $i"
        display_usage
        exit 1
    fi
done

for i in "${image_names[@]}"; do
    docker inspect "$i" &> /dev/null || failed_images+=("$i")
    if [[ ! "${failed_images[@]}" =~ "$i" ]]; then
        scan_images+=("$i")
    fi
done

if [[ "${#failed_images[@]}" -gt 0 ]]; then
    printf '\n\t%s\n\n' "## Please pull, build and/or tag all images before attempting analysis again. ##"
    if [[ "${#failed_images[@]}" -ge "${#image_names[@]}" ]]; then
        printf '\t%s\n\n' "ERROR - no local docker images specified in script input: $0 ${image_names[*]}"
        display_usage
        exit 1
    fi
    for i in "${failed_images[@]}"; do
        printf '\t\t%s\n' "Could not find image locally - $i"
    done
    echo
fi

if [[ -z "$ANCHORE_CI_IMAGE" ]]; then
    docker pull "$stateless_anchore_image"
fi

load_container() {
    docker save "$1" -o "/tmp/${2}"
    if [[ -f "/tmp/${2}" ]]; then
        docker cp "/tmp/${2}" "${docker_name}:/anchore-engine/${2}"
        rm -f "/tmp/${2}"
    else
        printf '\n%s\n\n' "ERROR - unable to save docker image to /tmp/${2}."
        exit 1
    fi
}


docker_name="${RANDOM:-TEMP}-stateless-anchore-engine"

if [[ ! "d_flag" ]] && [[ ! "p_flag" ]] && [[ "${#scan_images[@]}" -eq 1 ]]; then
    printf '\n%s\n\n' "Preparing image for analysis: ${scan_images[*]}"
    docker save "$i" | docker run -i --name "$docker_name" "$stateless_anchore_image" -i"${scan_images[]}"
else
    copy_cmds=()
    create_cmd=('docker create --name "$docker_name" "$stateless_anchore_image"')
    if [[ "$p_flag" ]]; then
        create_cmd+=('-p"$policy_bundle"')
        copy_cmds+=('docker cp "$policy_bundle" "${docker_name}:/anchore-engine/$(basename $policy_bundle)";')
    fi
    if [[ "$f_flag" ]]; then
        create_cmd+=('-f')
    fi
    if [[ "$d_flag" ]]; then
        create_cmd+=('-d"$dockerfile" -i"${scan_images[*]}"')
        copy_cmds+=('docker cp "$dockerfile" "${docker_name}:/anchore-engine/$(basename $dockerfile)";')
    fi
    docker_id=$(eval "${create_cmd[*]}")
    eval "${copy_cmds[*]}"

    for i in "${scan_images[@]}"; do
        printf '%s\n' "Preparing image for analysis: $i"
        repo="${i%:*}"
        tag="${i#*:}"
        file_name="${repo}+${tag}.tar" 
        load_container "$i" "$file_name"
    done
    echo
    docker start -ia "$docker_name"
fi
docker cp "${docker_name}:/anchore-engine/anchore-reports/" ./