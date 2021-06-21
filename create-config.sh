#!/bin/bash

getCertificateCommonName()
{
    openssl x509 -noout -subject -in "$1" |
        sed 's/^.*\/CN=\(.*\)$/\1/'
}

createSpki()
{
    openssl x509 -noout -pubkey -in "$1" |
        openssl pkey -pubin -outform DER |
        openssl dgst -sha256 -binary |
        openssl enc -base64
}

configBaseFolder="config"
for app in nsi-dds nsi-safnari nsi-pce
do
    configFolder=${configBaseFolder}/${app}
    if ! test -d "${configFolder}"
    then
        echo "ERROR: cannot find per application configuration folder(s) in config folder"
        exit 1
    fi
    truststore="charts/${app}/config/${app}-truststore.jks"
    echo ======================
	echo ${app} truststore
	echo ======================
	test -f "${truststore}" && rm "${truststore}" && echo removed old "${truststore}"
	for certificate in ${configFolder}/certificates/trust/*.crt ${configFolder}/certificates/trust/*.chain
	do
		if ! test -f "${certificate}"
		then 
            echo "WARNING: does ${app} not trust any peers???"
			break
		fi
		commonName=`getCertificateCommonName "${certificate}"`
		echo "adding certificate for ${commonName}"
		keytool -import -destkeystore "${truststore}" -alias "${commonName}" -storepass secret -noprompt -file "${certificate}"
	done

	echo ======================
	echo ${app} keystore
	echo ======================
    keystore="charts/${app}/config/${app}-keystore.jks"
    p12tmpkeystore="`mktemp`"
    certificate="`echo ${configFolder}/certificates/key/*.crt`"
    key="`echo ${configFolder}/certificates/key/*.key`"
    chain="`echo ${configFolder}/certificates/key/*.chain`"
	if test ! -f "${certificate}" -o ! -f "${key}" -o ! "${chain}"
	then 
		echo "ERROR: cannot find complete set of key, certifcate and chain for ${app}"
        exit 1
	fi
	test -f "${keystore}" && rm "${keystore}" && echo removed old "${keystore}"
    commonName=`getCertificateCommonName "${certificate}"`
	echo creating p12 keystore
	echo adding ${commonName} to p12 keystore
	openssl pkcs12 -export -name "${commonName}" -in "${certificate}" -inkey "${key}" -out "${p12tmpkeystore}" -CAfile "${chain}" -password pass:secret -chain
	echo converting pkcs12 keystore to jks
	keytool -importkeystore -destkeystore "${keystore}" -srckeystore "${p12tmpkeystore}" -srcstoretype pkcs12 -srcstorepass secret -storepass secret -alias "${commonName}" -noprompt
	test -f "${p12tmpkeystore}" && rm "${p12tmpkeystore}" && echo removed "${p12tmpkeystore}"
done

echo ======================
echo envoy configuration
echo ======================
envoyCaChain="charts/nsi-envoy/config/nsi-envoy-ca-chain.pem"
test -f "${envoyCaChain}"  && rm "${envoyCaChain}" && echo removed old "${envoyCaChain}"
for certificate in config/*/certificates/trust/*.chain
do
    if ! test -f "${certificate}"
    then
        echo "WARNING: could not find any CA to trust!"
        break
    fi
	echo adding CA to envoy chain: `getCertificateCommonName "${certificate}"`
	openssl x509 -noout -subject -issuer -in "${certificate}" >>"${envoyCaChain}"
	cat "${certificate}" >>"${envoyCaChain}"
done
envoyConfig="charts/nsi-envoy/config/envoy.yaml"
echo "creating envoy config ..."
test -f "${envoyConfig}"  && rm "${envoyConfig}" && echo removed old "${envoyConfig}"
echo "adding skeleton config ..."
cat "config/nsi-envoy/templates/envoy-head.yaml" >>${envoyConfig}
for app in nsi-dds nsi-safnari
do
    echo "copying ${app} key and chain to envoy config folder ..."
    cat config/${app}/certificates/key/*.key >charts/nsi-envoy/config/${app}.key
    cat config/${app}/certificates/key/*.chain >charts/nsi-envoy/config/${app}.chain
    cat "config/${app}/templates/envoy-filter_chain_match.yaml" >>${envoyConfig}
    echo "              verify_certificate_spki:" >>${envoyConfig}
    for certificate in config/${app}/certificates/trust/*.crt
    do
        if ! test -f "${certificate}"
        then
            echo "WARNING: does ${app} not trust any peers???"
            break
        fi
        spki=`createSpki "${certificate}"`
        commonName=`getCertificateCommonName "${certificate}"`
        echo "adding ${commonName} SPKI to ${app} envoy config"
        echo "              - \"${spki}\" # ${commonName}" >>${envoyConfig}
    done
done
echo "  clusters:" >>${envoyConfig}
for app in nsi-dds nsi-safnari
do
    echo "adding ${app} cluster config ..."
    cat "config/${app}/templates/envoy-cluster.yaml" >>${envoyConfig}
done
