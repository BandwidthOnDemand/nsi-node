#!/usr/bin/env zsh

declare -A levels
levels[DEBUG]=0
levels[INFO]=1
levels[WARN]=2
levels[ERROR]=3
script_logging_level="INFO"
configBaseFolder="config"


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

appEnabled() {
    [ `yq eval .$1.enabled values.yaml | tr A-Z a-z` = "true" ]
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

checkConfigFolders() {
    configFolders=()
    for app in nsi-safnari nsi-pce nsi-dds nsi-envoy
    do
        case ${app} in
            nsi-dds )
                configFolders+="${configBaseFolder}/nsi-dds/templates"
                configFolders+="${configBaseFolder}/nsi-dds/certificates/key"
                configFolders+="${configBaseFolder}/nsi-dds/certificates/trust"
                ;;
            nsi-safnari )
                configFolders+="${configBaseFolder}/nsi-safnari/templates"
                configFolders+="${configBaseFolder}/nsi-safnari/certificates/key"
                configFolders+="${configBaseFolder}/nsi-safnari/certificates/trust"
                ;;
            nsi-pce )
                configFolders+="${configBaseFolder}/nsi-pce/templates"
                configFolders+="${configBaseFolder}/nsi-pce/certificates/key"
                configFolders+="${configBaseFolder}/nsi-pce/certificates/trust"
                ;;
            nsi-envoy )
                configFolders+="${configBaseFolder}/nsi-envoy/templates"
                ;;
        esac
    done
    local error=false
    for configFolder in ${configFolders}
    do
        if [ ! -d "${configFolder}" ]
        then
            log ERROR "folder does not exist: ${configFolder}"
            error=true
        fi
    done
    if [ ${error} = true ]
    then
        log ERROR "cannot continue, exiting!"
        exit 1
    fi
}


getCertificateCommonName() {
    openssl x509 -noout -subject -in "$1" |
        sed 's/^.*\/CN=\(.*\)$/\1/'
}

createSpki() {
    openssl x509 -noout -pubkey -in "$1" |
        openssl pkey -pubin -outform DER |
        openssl dgst -sha256 -binary |
        openssl enc -base64
}

#
# get and untar Helm charts
#
getHelmCharts()
{
    test ! -f Chart.yaml && log ERROR cannot find Chart.yaml && exit 1
    test ! -f values.yaml && log ERROR cannot find values.yaml && exit 1
    helm dependency update --skip-refresh || { log ERROR helm dependency update failed; exit 1 }
    (
        cd charts
        for chart in *.tgz
        do
            tar -xf "$chart" && rm -f "$chart"
        done
    )
    for app in nsi-safnari nsi-pce nsi-dds nsi-envoy
    do
        if appEnabled ${app} && test ! -d "charts/${app}/config"
        then
            mkdir "charts/${app}/config" && log DEBUG "created folder ${app}/config"
        fi
    done
}

#
# create per app config
#
createAppConfig() {
    for app in nsi-dds nsi-safnari nsi-pce
    do
        log INFO "======================"
        log INFO "`echo ${app} | tr a-z A-Z`"
        log INFO "======================"
        configFolder="${configBaseFolder}/${app}"
        runtimeConfigFolder="charts/${app}/config"
        #
        # create truststore
        #
        CNs=()
        truststore="charts/${app}/config/${app}-truststore.jks"
        ifExistExecute DEBUG "${truststore}" 'rm ${file} && log DEBUG removed old ${file}'
        find "${configFolder}/certificates/trust" \( -name '*.crt' -o -name '*.chain' \) -print | while read certificate
        do
            commonName=`getCertificateCommonName "${certificate}"`
            if (($CNs[(I)$commonName]))
            then
                log DEBUG "already in truststore: ${commonName}"
                continue
            fi
            CNs+="${commonName}"
            log INFO "adding certificate to truststore: ${commonName}"
            keytool -import -destkeystore "${truststore}" -alias "${commonName}" -storepass secret -noprompt -file "${certificate}" 2>/dev/null || log ERROR "could not import certificate"
        done
        #
        # create keystore
        #
        keystore="charts/${app}/config/${app}-keystore.jks"
        p12tmpkeystore="`mktemp`"
        certificate="`echo ${configFolder}/certificates/key/*.crt`"
        key="`echo ${configFolder}/certificates/key/*.key`"
        chain="`echo ${configFolder}/certificates/key/*.chain`"
        if test ! -f "${certificate}" -o ! -f "${key}" -o ! "${chain}"
        then 
            log ERROR "cannot find complete set of key, certifcate and chain for ${app}"
            exit 1
        fi
        ifExistExecute DEBUG "${keystore}" 'rm ${file} && log DEBUG removed old ${file}'
        commonName=`getCertificateCommonName "${certificate}"`
        log DEBUG "creating p12 keystore"
        log INFO "adding certificate to keystore: ${commonName}"
        openssl pkcs12 -export -name "${commonName}" -in "${certificate}" -inkey "${key}" -out "${p12tmpkeystore}" -CAfile "${chain}" -password pass:secret -chain
        log DEBUG "converting pkcs12 keystore to jks"
        keytool -importkeystore -destkeystore "${keystore}" -srckeystore "${p12tmpkeystore}" -srcstoretype pkcs12 -srcstorepass secret -storepass secret -alias "${commonName}" -noprompt 2>/dev/null ||
            log ERROR "could not covert keystore from p12 to jks"
        ifExistExecute DEBUG "${p12tmpkeystore}" 'rm ${file} && log DEBUG removed ${file}'
        #
        # copying config files
        #
        log INFO "installing config file(s)"
        configFiles=()
        case ${app} in
            nsi-dds )
                configFiles+=dds.xml
                configFiles+=log4j.xml
                configFiles+=logging.properties
                ;;
            nsi-safnari )
                configFiles+=config-overrides.conf
                ;;
            nsi-pce )
                configFiles+=log4j.xml
                configFiles+=logging.properties
                configFiles+=topology-dds.xml
                configFiles+=beans.xml
                configFiles+=http.json
                ;;
        esac
        for file in ${configFiles}
        do
            ifExistExecute ERROR ""${configFolder}/templates/${file} "cp -p \${file} ${runtimeConfigFolder} && log DEBUG installed \${file}"
        done
    done
}
#
# create envoy config
#
createEnvoyConfig() {
    log INFO "======================"
    log INFO ENVOY
    log INFO "======================"
    envoyCaChain="charts/nsi-envoy/config/nsi-envoy-ca-chain.pem"
    runtimeConfigFolder="charts/nsi-envoy/config"
    ifExistExecute DEBUG "${envoyCaChain}" 'rm ${file} && log DEBUG removed old ${file}'
    find "config" -name '*.chain' -regex '.*/trust/[^/]*\.chain' | while read certificate
    do
        if ! test -f "${certificate}"
        then
            log WARN "could not find any CA to trust!"
            break
        fi
        log INFO "adding CA to envoy chain:" `getCertificateCommonName "${certificate}"`
        openssl x509 -noout -subject -issuer -in "${certificate}" >>"${envoyCaChain}"
        cat "${certificate}" >>"${envoyCaChain}"
    done
    envoyConfig="charts/nsi-envoy/config/envoy.yaml"
    log DEBUG "creating envoy config"
    ifExistExecute DEBUG "${envoyConfig}" 'rm ${file} && log DEBUG removed old ${file}'
    log DEBUG "adding skeleton config ..."
    ifExistExecute ERROR "${configBaseFolder}/nsi-envoy/templates/envoy-head.yaml" "cat \${file} >>${envoyConfig}"
    for app in nsi-dds nsi-safnari
    do
        log INFO "copying ${app} key and chain to envoy config folder"
        cat ${configBaseFolder}/${app}/certificates/key/*.key >charts/nsi-envoy/config/${app}.key
        cat ${configBaseFolder}/${app}/certificates/key/*.chain >charts/nsi-envoy/config/${app}.chain
        ifExistExecute ERROR "${configBaseFolder}/${app}/templates/envoy-filter_chain_match.yaml" "cat \${file} >>${envoyConfig}"
        echo "              verify_certificate_spki:" >>${envoyConfig}
        find "${configBaseFolder}/${app}/certificates/trust" -name '*.crt' -print | while read certificate
        do
            spki=`createSpki "${certificate}"`
            commonName=`getCertificateCommonName "${certificate}"`
            log INFO "adding SPKI to ${app} envoy config: ${commonName}"
            echo "              - \"${spki}\" # ${commonName}" >>${envoyConfig}
        done
    done
    echo "  clusters:" >>${envoyConfig}
    for app in nsi-dds nsi-safnari
    do
        log DEBUG "adding ${app} cluster config ..."
        ifExistExecute ERROR "${configBaseFolder}/${app}/templates/envoy-cluster.yaml" "cat \${file} >>${envoyConfig}"
    done
}

#
# main
#
while getopts ":dc:" opt
do
    case ${opt} in
        d )
            script_logging_level="DEBUG"
            ;;
        c )
            configBaseFolder="${OPTARG}"
            log DEBUG "using ${configBaseFolder} as configuration folder"
            ;;
        ":" )
            log ERROR "option -${OPTARG} requires an argument"
            exit 1
            ;;
        \? )
            echo "Usage: `basename $0` [-d] [-c <configfolder>]"
            exit 1
            ;;
    esac
done
shift $((OPTIND -1))

checkConfigFolders
getHelmCharts
createAppConfig
createEnvoyConfig
