#!/usr/bin/env zsh

declare -A levels=([DEBUG]=0 [INFO]=1 [WARN]=2 [ERROR]=3)
script_logging_level="INFO"

while getopts ":d" opt
do
    case ${opt} in
        d )
            script_logging_level="DEBUG"
            ;;
        \? )
            echo "Usage: `basename $0` [-d]"
            exit 1
            ;;
    esac
done
shift $((OPTIND -1))

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

createConfigFolders() {
    configFolders=()
    for app in nsi-safnari nsi-pce nsi-dds nsi-envoy
    do
        configFolders+="charts/${app}/config"
    done
    for app in nsi-safnari nsi-pce nsi-dds
    do
        configFolders+="config/${app}/certificates/key"
        configFolders+="config/${app}/certificates/trust"
    done
    for configFolder in ${configFolders}
    do
        test ! -d "${configFolder}" && mkdir "${configFolder}" && log DEBUG "created folder ${configFolder}"
    done
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

createConfigFolders
configBaseFolder="config"
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
	test -f "${truststore}" && rm "${truststore}" && log DEBUG "removed old ${truststore}"
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
	test -f "${keystore}" && rm "${keystore}" && log "DEBUG removed old ${keystore}"
    commonName=`getCertificateCommonName "${certificate}"`
	log DEBUG "creating p12 keystore"
	log INFO "adding certificate to keystore: ${commonName}"
	openssl pkcs12 -export -name "${commonName}" -in "${certificate}" -inkey "${key}" -out "${p12tmpkeystore}" -CAfile "${chain}" -password pass:secret -chain
	log DEBUG "converting pkcs12 keystore to jks"
	keytool -importkeystore -destkeystore "${keystore}" -srckeystore "${p12tmpkeystore}" -srcstoretype pkcs12 -srcstorepass secret -storepass secret -alias "${commonName}" -noprompt 2>/dev/null ||
        log ERROR "could not covert keystore from p12 to jks"
	test -f "${p12tmpkeystore}" && rm "${p12tmpkeystore}" && log DEBUG "removed ${p12tmpkeystore}"
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
        cp -p ${configFolder}/templates/${file} ${runtimeConfigFolder} && log DEBUG "installed" ${file}
    done
done

log INFO "======================"
log INFO ENVOY
log INFO "======================"
envoyCaChain="charts/nsi-envoy/config/nsi-envoy-ca-chain.pem"
runtimeConfigFolder="charts/nsi-envoy/config"
test -f "${envoyCaChain}"  && rm "${envoyCaChain}" && log DEBUG "removed old ${envoyCaChain}"
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
test -f "${envoyConfig}"  && rm "${envoyConfig}" && log DEBUG "removed old ${envoyConfig}"
log DEBUG "adding skeleton config ..."
cat "config/nsi-envoy/templates/envoy-head.yaml" >>${envoyConfig}
for app in nsi-dds nsi-safnari
do
    log INFO "copying ${app} key and chain to envoy config folder"
    cat config/${app}/certificates/key/*.key >charts/nsi-envoy/config/${app}.key
    cat config/${app}/certificates/key/*.chain >charts/nsi-envoy/config/${app}.chain
    cat "config/${app}/templates/envoy-filter_chain_match.yaml" >>${envoyConfig}
    echo "              verify_certificate_spki:" >>${envoyConfig}
    find "config/${app}/certificates/trust" -name '*.crt' -print | while read certificate
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
    cat "config/${app}/templates/envoy-cluster.yaml" >>${envoyConfig}
done
