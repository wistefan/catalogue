#!/bin/bash

user="<username>"
password="<password>"

usage() {
    echo "Usage: $0 [-pv] [IMAGE_NAME]"
    echo
    echo "Options:"
    echo " -p : Pull images before running scan"
    echo " -v : Verbose output"
    echo " -h : This help message"
    echo
    echo "[IMAGE_NAME] : (Optional) Docker image file to be analysed."
    echo "               If it is not provided the Docker images are "
    echo "               obtained from the enablers.json file."
    exit 1
}

redirect_stderr() {
    if [[ ${VERBOSE} -eq 1 ]]; then
        "$@"
    else
        "$@" 2>/dev/null
    fi
}

redirect_all() {
    if [[ ${VERBOSE} -eq 1 ]]; then
        "$@"
    else
        "$@" 2>/dev/null >/dev/null
    fi
}

security_analysis() {
    redirect_all echo "Pulling from "$@"..."
    redirect_all docker pull "$@"
    redirect_all echo

    labels=$(docker inspect --type=image "$@" 2>/dev/null | jq .[].Config.Labels)

    if [[ ${PULL} -eq 1 ]];
    then
      redirect_all echo "Pulling Clair content ..."
      redirect_all docker-compose pull
      redirect_all echo
    fi

    redirect_all echo "Security analysis of "$@" image..."
    extension="$(date +%Y%m%d_%H%M%S).json"
    filename=$(echo "$@" | awk -F '/' -v a="$extension" '{print $2 a}')
    enabler=$(echo "$@" | awk -F '/' '{print $2}')

    redirect_stderr docker-compose run --rm scanner "$@" > ${filename}
    ret=$?
    redirect_all echo

    redirect_all echo "Removing docker instances..."
    redirect_all docker-compose down
    redirect_all echo

    line=$(grep 'latest: Pulling from arminc\/clair-db' ${filename})

    # Just for the 1st time...
    if [[ -n ${line} ]]; then
	    # Delete first 3 lines of the file due to the first time that it is executed
	    # it includes 3 extra no needed lines
	    sed -i '1,3 d' ${filename}
    fi

    # Just to finish, send the data to the nexus instance
    redirect_all curl -v -u ${user}':'${password} --upload-file ${filename}  https://nexus.lab.fiware.org/repository/security/check/${enabler}/cve/${filename}

    # Send an email to the owner of the FIWARE GE

}

docker_bench_security() {
    cd ../docker-bench-security

    id=$(docker images | grep -E "$@" | awk -e '{print $3}')

    redirect_all ./docker-bench-security.sh  -t "$@" -c container_images,container_runtime,docker_security_operations

    extension="$(date +%Y%m%d_%H%M%S).json"
    filename=$(echo "$@" | awk -F '/' -v a="$extension" '{print $2 a}')
    enabler=$(echo "$@" | awk -F '/' '{print $2}')

    mv docker-bench-security.sh.log.json ${filename}

    redirect_all echo "Clean up the docker image..."
    redirect_all docker rmi ${id}
    redirect_all echo

    redirect_all curl -v -u ${user}':'${password} --upload-file ${filename}  https://nexus.lab.fiware.org/repository/security/check/${enabler}/bench-security/${filename}

    cd ../clair-container-scan
}

init() {
    BASEDIR=$(cd $(dirname "$0") && pwd)
    cd "$BASEDIR"

    if [[ ! -f "docker-compose.yml" ]]; then
        wget -q https://raw.githubusercontent.com/flopezag/fiware-clair/develop/docker/docker-compose.yml
    fi

    if [[ ! -f "enablers.json" ]]; then
        wget -q https://raw.githubusercontent.com/flopezag/fiware-clair/develop/docker/enablers.json
    fi

    cd ..

    if [[ ! -d "docker-bench-security" ]]; then
        redirect_all git clone https://github.com/docker/docker-bench-security.git
    fi

    echo $BASEDIR
    cd "$BASEDIR"
}

PULL=0
VERBOSE=0

while getopts ":phv" opt; do
    case ${opt} in
        p)
            PULL=1
            ;;
        v)
            VERBOSE=1
            ;;
        \?)
            echo "Invalid option: -$OPTARG" >&2
            usage
            ;;
        h)
            usage
            ;;
    esac
done
shift $(($OPTIND -1))

init

if [[ -n $1 ]]; then
    security_analysis "$1"
    docker_bench_security "$1"
else
    for ge in `more enablers.json | jq .enablers[].image | sed 's/"//g'`
    do
      security_analysis ${ge}
      docker_bench_security ${ge}
      redirect_all echo
      redirect_all echo
    done
fi

exit ${ret}