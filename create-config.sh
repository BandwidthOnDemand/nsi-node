#!/usr/bin/env zsh

declare -A levels
levels[DEBUG]=0
levels[INFO]=1
levels[WARN]=2
levels[ERROR]=3
script_logging_level="INFO"
configBaseFolder="config"
postgresqlInitDb="charts/postgresql/initdb.d"


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
    for app in nsi-safnari nsi-pce nsi-dds nsi-envoy nsi-opennsa nsi-requester
    do
        appEnabled ${app} || continue
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
            nsi-opennsa )
                configFolders+="${configBaseFolder}/nsi-opennsa/templates"
                configFolders+="${configBaseFolder}/nsi-opennsa/certificates/key"
                configFolders+="${configBaseFolder}/nsi-opennsa/certificates/trust"
                configFolders+="${configBaseFolder}/nsi-opennsa/backends"
                ;;
            nsi-requester )
                configFolders+="${configBaseFolder}/nsi-requester/templates"
                configFolders+="${configBaseFolder}/nsi-requester/certificates/key"
                configFolders+="${configBaseFolder}/nsi-requester/certificates/trust"
                ;;
            polynsi )
                configFolders+="${configBaseFolder}/nsi-requester/templates"
                configFolders+="${configBaseFolder}/nsi-requester/certificates/key"
                configFolders+="${configBaseFolder}/nsi-requester/certificates/trust"
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

#
# copy config files
#
copyConfigFiles() {
    local app=$1
    local configFolder=$2
    local runtimeConfigFolder=$3
    log INFO "install config file(s)"
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
        nsi-opennsa )
            configFiles+=opennsa.conf
            configFiles+=opennsa.tac
            ;;
        nsi-requester )
            configFiles+=config-overrides.conf
            ;;
        polynsi )
            configFiles+=application.properties
            configFiles+=logback-spring.xml
            ;;
    esac
    for file in ${configFiles}
    do
        ifExistExecute ERROR ""${configFolder}/templates/${file} "cp -p \${file} ${runtimeConfigFolder} && log DEBUG installed \${file}"
    done
}

#
# get certificate common name, if empty return organisational unit, otherwise
# just return distinguished name
#
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
    helm dependency update || { log ERROR helm dependency update failed; exit 1 }
    (
        cd charts
        rm -rf nsi-safnari nsi-pce nsi-dds nsi-envoy nsi-opennsa nsi-requester postgresql && log DEBUG "removed old chart folders"
        for chart in *.tgz
        do
            tar -xf "$chart" && rm -f "$chart"
        done
    )
    for app in nsi-safnari nsi-pce nsi-dds nsi-envoy nsi-opennsa nsi-requester polynsi
    do
        if appEnabled ${app} && test ! -d "charts/${app}/config"
        then
            mkdir "charts/${app}/config" && log DEBUG "created folder ${app}/config"
        fi
    done
}

#
# create per Java app config
#
createAppConfig() {
    for app in nsi-dds nsi-safnari nsi-pce nsi-requester polynsi
    do
        appEnabled ${app} || continue
        log INFO "======================"
        log INFO "`echo ${app} | tr a-z A-Z`"
        log INFO "======================"
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
            keytool -import -destkeystore "${truststore}" -alias "${commonName}" -storepass secret -noprompt -file "${certificate}" 2>/dev/null || log ERROR "could not import certificate"
        done
        #
        # create keystore
        #
        keystore="${runtimeConfigFolder}/${app}-keystore.jks"
        p12tmpkeystore="`mktemp`"
        tmpchain="`mktemp`"
        cat ${configFolder}/certificates/key/*.chain >$tmpchain
        certificate="`echo ${configFolder}/certificates/key/*.crt`"
        key="`echo ${configFolder}/certificates/key/*.key`"
        if test ! -s "${certificate}" -o ! -s "${key}" -o ! -s "${tmpchain}"
        then 
            log ERROR "cannot find complete set of key, certifcate and chain for ${app}"
            exit 1
        fi
        ifExistExecute DEBUG "${keystore}" 'rm ${file} && log DEBUG removed old ${file}'
        commonName=`getCertificateCommonName "${certificate}"`
        log DEBUG "creat p12 keystore"
        log INFO "add certificate to keystore: ${commonName}"
        openssl pkcs12 -export -name "${commonName}" -in "${certificate}" -inkey "${key}" -out "${p12tmpkeystore}" -CAfile "${tmpchain}" -password pass:secret -chain
        log DEBUG "convert pkcs12 keystore to jks"
        keytool -importkeystore -destkeystore "${keystore}" -srckeystore "${p12tmpkeystore}" -srcstoretype pkcs12 -srcstorepass secret -storepass secret -alias "${commonName}" -noprompt 2>/dev/null ||
            log ERROR "could not covert keystore from p12 to jks"
        ifExistExecute DEBUG "${p12tmpkeystore}" 'rm ${file} && log DEBUG removed ${file}'
        ifExistExecute DEBUG "${tmpchain}" 'rm ${file} && log DEBUG removed ${file}'
        #
        # copy config files
        #
        copyConfigFiles ${app} ${configFolder} ${runtimeConfigFolder}
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
    find "${configBaseFolder}" -name '*.chain' -regex '.*/trust/[^/]*\.chain' | while read certificate
    do
        if ! test -f "${certificate}"
        then
            log WARN "could not find any CA to trust!"
            break
        fi
        log INFO "add CA to envoy chain:" `getCertificateCommonName "${certificate}"`
        openssl x509 -noout -subject -issuer -in "${certificate}" >>"${envoyCaChain}"
        cat "${certificate}" >>"${envoyCaChain}"
    done
    envoyConfig="charts/nsi-envoy/config/envoy.yaml"
    log DEBUG "create envoy config"
    ifExistExecute DEBUG "${envoyConfig}" 'rm ${file} && log DEBUG removed old ${file}'
    log DEBUG "add skeleton config ..."
    ifExistExecute ERROR "${configBaseFolder}/nsi-envoy/templates/envoy-head.yaml" "cat \${file} >>${envoyConfig}"
    for app in nsi-dds nsi-safnari nsi-opennsa nsi-requester polynsi
    do
        appEnabled ${app} || continue
        log INFO "copy ${app} key and chain to envoy config folder"
        cat ${configBaseFolder}/${app}/certificates/key/*.key >charts/nsi-envoy/config/${app}.key
        cat ${configBaseFolder}/${app}/certificates/key/*.{crt,chain} >charts/nsi-envoy/config/${app}.chain
        ifExistExecute ERROR "${configBaseFolder}/${app}/templates/envoy-filter_chain_match.yaml" "cat \${file} >>${envoyConfig}"
        echo "              verify_certificate_spki:" >>${envoyConfig}
        find "${configBaseFolder}/${app}/certificates/trust" -name '*.crt' -maxdepth 1 -print | while read certificate
        do
            spki=`createSpki "${certificate}"`
            commonName=`getCertificateCommonName "${certificate}"`
            log INFO "add SPKI to ${app} envoy config: ${commonName}"
            echo "              - \"${spki}\" # ${commonName}" >>${envoyConfig}
        done
    done
    echo "  clusters:" >>${envoyConfig}
    for app in nsi-dds nsi-safnari nsi-opennsa nsi-requester polynsi
    do
        appEnabled ${app} || continue
        log DEBUG "add ${app} cluster config ..."
        ifExistExecute ERROR "${configBaseFolder}/${app}/templates/envoy-cluster.yaml" "cat \${file} >>${envoyConfig}"
    done
}

#
# create OpenNSA config
#
createOpennsaConfig() {
    log INFO "======================"
    log INFO "OPENNSA"
    log INFO "======================"
    configFolder="${configBaseFolder}/nsi-opennsa"
    runtimeConfigFolder="charts/nsi-opennsa/config"
    runtimeCertificatesFolder="charts/nsi-opennsa/certificates"
    runtimeBackendsFolder="charts/nsi-opennsa/backends"
    mkdir "${runtimeCertificatesFolder}" || log ERROR "cannot create ${runtimeCertificatesFolder}"
    mkdir "${runtimeBackendsFolder}" || log ERROR "cannot create ${runtimeBackendsFolder}"
    find "${configFolder}"/certificates/{trust,key} \( -name '*.crt' -o -name '*.chain' \) -maxdepth 1 -print | while read certificate
    do
        certificateHash=`openssl x509 -noout -hash -in ${certificate}`
        commonName=`getCertificateCommonName "${certificate}"`
        cp -p "${certificate}" "${runtimeCertificatesFolder}/${certificateHash}.0" && \
            log INFO "add certificate ${certificateHash}.0: ${commonName}" || \
            log ERROR "cannot add certificate: ${certificate}"
    done
    find "${configFolder}/backends" -type f -maxdepth 1 -print | while read backend
    do
        cp -p "${backend}" "${runtimeBackendsFolder}" && \
            log INFO "add backend: "`basename "${backend}"` || \
            log ERROR "cannot add backend: ${backend}"
    done
    find "${configFolder}/templates" -type f -name "*.nrm" -maxdepth 1 -print | while read nrm
    do
        cp -p "${nrm}" "${runtimeConfigFolder}" && \
            log INFO "add nrm file: "`basename "${nrm}"` || \
            log ERROR "cannot add  nrm file: ${nrm}"
    done
    if test -d "${configFolder}/credentials"
    then
        find "${configFolder}/credentials" -type f -maxdepth 1 -print | while read credential
        do
            cp -p "${credential}" "${runtimeConfigFolder}" && \
                log INFO "add credential: "`basename "${credential}"` || \
                log ERROR "cannot add credential: ${credential}"
        done
    fi
    cp -p ${configFolder}/certificates/key/*.key ${runtimeConfigFolder}/server.key && \
        log INFO "add server key" || \
        log ERROR "cannot add  server key"
    cp -p ${configFolder}/certificates/key/*.crt ${runtimeConfigFolder}/server.crt && \
        log INFO "add server certificate" || \
        log ERROR "cannot add  server certificate"
    #
    # copy config files
    #
    copyConfigFiles "nsi-opennsa" ${configFolder} ${runtimeConfigFolder}
}

createPostgresqlConfig() {
    log INFO "======================"
    log INFO "POSTGRESQL"
    log INFO "======================"
    mkdir -p "${postgresqlInitDb}" && log DEBUG "created folder ${postgresqlInitDb}"
    for app in nsi-safnari nsi-opennsa
    do
        appEnabled ${app} || continue
        configFolder="${configBaseFolder}/${app}"
        cp -p "${configFolder}/templates/create-postgres-db.sh" "${postgresqlInitDb}/${app}.sh" 2>/dev/null && \
            log INFO "install ${app} init db script" || \
            log ERROR "cannot install ${app} init db script"
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
            log DEBUG "use ${configBaseFolder} as configuration folder"
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
appEnabled nsi-opennsa && createOpennsaConfig
appEnabled nsi-envoy && createEnvoyConfig
appEnabled postgresql && createPostgresqlConfig
exit 0
