#!/usr/bin/env zsh

declare -A levels
levels[DEBUG]=0
levels[INFO]=1
levels[WARN]=2
levels[ERROR]=3
script_logging_level="INFO"
configBaseFolder="config"

getCertificateCommonName() {
    DN=`openssl x509 -noout -subject -in "$1"`
    CN=`echo "$DN" | sed -e 's/^subject= //' -e 's/^.*\/CN=\(.*\)$/\1/' -e 's"/.*$""'`
    if test -n "$CN"
    then
        echo "$CN"
    else
        OU=`echo "$DN" | sed -e 's/^subject= //' -e 's/^.*\/OU=\(.*\)$/\1/' -e 's"/.*$""'`
        if test -n "$OU"
        then
            echo "$OU"
        else
            echo "$DN"
        fi
    fi
}

log() {
    local log_priority=$1
    local log_message=${@:2}

    #check if level exists
    [[ ${levels[$log_priority]} ]] || return 1

    #check if level is enough
    (( ${levels[$log_priority]} < ${levels[$script_logging_level]} )) && return 2

    #log here
    printf "%-5s %s\n" "${log_priority}" "${log_message}"
}

ifExistExecute() {
    local log_priority=$1
    shift
    local file="${1}"
    shift
    if test -f "${file}"
    then
        eval ${@}
    else
        log ${log_priority} ${file} does not exist
    fi
}

while getopts ":dc:" opt
do
    case ${opt} in
        d )
            script_logging_level="DEBUG"
            ;;
        c )
            configBaseFolder="${OPTARG}"
            log DEBUG "use ${configBaseFolder} as configuration folder"
            ;;
        ":" )
            log ERROR "option -${OPTARG} requires an argument"
            exit 1
            ;;
        \? )
            echo "Usage: `basename $0` [-d] [-c <configfolder>] <app>"
            exit 1
            ;;
    esac
done
shift $((OPTIND -1))

if test $# -ne 1
then
    echo "Usage: `basename $0` [-d] [-c <configfolder>] <app>"
    exit 1
else
    app="$1"
fi

configFolder="${configBaseFolder}/${app}"
runtimeConfigFolder="charts/${app}/config"
#
# create truststore
#
CNs=()
truststore="${runtimeConfigFolder}/${app}-truststore.jks"
ifExistExecute DEBUG "${truststore}" 'rm ${file} && log DEBUG removed old ${file}'
find "${configFolder}/certificates/trust" \( -name '*.crt' -o -name '*.chain' \) -maxdepth 1 -print | while read certificate
do
    commonName=`getCertificateCommonName "${certificate}"`
    if (($CNs[(I)$commonName]))
    then
        log DEBUG "already in truststore: ${commonName}"
        continue
    fi
    CNs+="${commonName}"
    log INFO "add certificate to truststore: ${commonName}"
    keytool -import -destkeystore "${truststore}" -deststoretype jks -alias "${commonName}" -storepass secret -noprompt -file "${certificate}" 2>/dev/null || log ERROR "could not import certificate"
done

log INFO "created trust store ${truststore}"
