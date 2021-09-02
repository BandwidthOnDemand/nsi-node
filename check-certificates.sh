#! /usr/bin/env zsh

#
# array's to store certificate info by key and DN
#
initializeArrays() {
    declare -g -A fileByKey=()
    declare -g -A fileByDn=()
    declare -g -A subjectDnByKey=()
    declare -g -A subjectDnByDn=()
    declare -g -A issuerDnByKey=()
    declare -g -A issuerDnByDn=()
    declare -g -A issuerKeyByKey=()
    declare -g -A issuerKeyByDn=()
    declare -g -A notBeforeByKey=()
    declare -g -A notBeforeByDn=()
    declare -g -A notAfterByKey=()
    declare -g -A notAfterByDn=()
}

#
# load all information from given certificate and add to environment
#
getCertificateDetails() {
    unset subjectKey authorityKey issuer subject notBefore notAfter
    tmpfile=`mktemp`
    openssl x509 -noout -text -in "$1" |
        awk '
            /X509v3 Subject Key Identifier:/ {
                getline;
                printf "subjectKey=\"%s\"\n", $1
            }
            /X509v3 Authority Key Identifier:/ {
                getline;
                sub("keyid:", "");
                printf "authorityKey=\"%s\"\n", $1
            }
            /Issuer:/{
                sub("^ *Issuer: ", "");
                printf "issuer=\"%s\"\n", $0
            }
            /Subject:/{
                sub("^ *Subject: ", "");
                printf "subject=\"%s\"\n", $0
            }
            /Not Before:/{
                sub("^ *Not Before: ","");
                printf "notBefore=\"%s\"\n", $0
            }
            /Not After :/{
                sub("^ *Not After : ","");
                printf "notAfter=\"%s\"\n", $0
            }
        ' >$tmpfile
    . $tmpfile
    rm $tmpfile
}

#
# load all .chain certificates from given directory
#
loadChainCertificates() {
    if test ! -d "$1"
    then
        echo "$1" is not a directory
        exit 1
    fi
    find "$1" -maxdepth 1 -name '*.chain' -print |
        while read file
        do
            getCertificateDetails "$file"
            if test -z "$subjectKey"
            then
                fileByDn["$subject"]="$file"
                subjectDnByDn["$subject"]="$subject"
                issuerDnByDn["$subject"]="$issuer"
                notBeforeByDn["$subject"]="$notBefore"
                notAfterByDn["$subject"]="$notAfter"
            else
                fileByKey["$subjectKey"]="$file"
                fileByDn["$subject"]="$file"
                subjectDnByKey["$subjectKey"]="$subject"
                subjectDnByDn["$subject"]="$subject"
                issuerDnByKey["$subjectKey"]="$issuer"
                issuerDnByDn["$subject"]="$issuer"
                issuerKeyByKey["$subjectKey"]="$authorityKey"
                issuerKeyByDn["$subject"]="$authorityKey"
                notBeforeByKey["$subjectKey"]="$notBefore"
                notBeforeByDn["$subject"]="$notBefore"
                notAfterByKey["$subjectKey"]="$notAfter"
                notAfterByDn["$subject"]="$notAfter"
            fi
        done
}

#
# test if 'not After' date is past now
#
certificateExpired () {
    cert=`date -j -f '%b %e %H:%M:%S %Y %Z' '+%s' "$1"`
    now=`date '+%s'`
    [ $now -ge $cert ]
}

#
# for all .crt in given directory verify that there is a complate set of .chain
# certificates and that all are not expired
#
verifyCertificateChains() {
    if test ! -d "$1"
    then
        echo "$1" is not a directory
        exit 1
    fi
    totalNumberOfCertificates=0
    totalNumberOfCompleteChains=0
    find "$1" -maxdepth 1 -name '*.crt' -print |
        while read file
        do
            #
            # get and print certificate info
            #
            indent=""
            ((totalNumberOfCertificates++))
            getCertificateDetails "$file"
            print "$subject"
            test -n "$subjectKey" && print "$subjectKey"
            print "$file"
            if certificateExpired "$notAfter"
            then
                print -P "%F{red}${indent}not valid after $notAfter%F{none}"
                continue
            else
                print "${indent}$notAfter"
            fi
            ((totalNumberOfCompleteChains++))
            #
            # get and print chain info
            #
            while true; do
                indent+="    "
                if test -z "$subjectDnByKey["$authorityKey"]" -a -z "$subjectDnByDn["$issuer"]"
                then
                    print -P "%F{red}${indent}cannot find: $issuer ($authorityKey)%F{none}"
                    ((totalNumberOfCompleteChains--))
                    break
                fi
                if test -z "$authorityKey"
                then
                    print -P "%F{green}${indent}$issuer%F{none}"
                    print -P "%F{green}${indent}$fileByDn["$issuer"]%F{none}"
                    if certificateExpired "$notAfterByDn["$issuer"]"
                    then
                        print -P "%F{red}${indent}not valid after $notAfterByDn["$issuer"]%F{none}"
                        ((totalNumberOfCompleteChains--))
                        break
                    else
                        print -P "%F{green}${indent}$notAfterByDn["$issuer"]%F{none}"
                    fi
                    subjectKey=$authorityKey
                    subject="$issuer"
                    authorityKey=$issuerKeyByKey["$authorityKey"]
                    issuer=$issuerDnByDn["$issuer"]
                    test "$issuer" != "$subject" || break
                else
                    print -P "%F{green}${indent}$subjectDnByKey["$authorityKey"]%F{none}"
                    print -P "%F{green}${indent}$authorityKey%F{none}"
                    print -P "%F{green}${indent}$fileByKey["$authorityKey"]%F{none}"
                    if certificateExpired "$notAfterByKey["$authorityKey"]"
                    then
                        print -P "%F{red}${indent}not valid after $notAfterByKey["$authorityKey"]%F{none}"
                        ((totalNumberOfCompleteChains--))
                        break
                    else
                        print -P "%F{green}${indent}$notAfterByKey["$authorityKey"]%F{none}"
                    fi
                    subject=$subjectDnByKey["$authorityKey"]
                    issuer=$issuerDnByKey["$authorityKey"]
                    subjectKey=$authorityKey
                    authorityKey=$issuerKeyByKey["$authorityKey"]
                    if test -z "$authorityKey"
                    then
                        test "$issuer" != "$subject" || break
                    else
                        test "$authorityKey" != "$subjectKey" || break
                    fi
                fi
            done
        done
        ((totalNumberOfCertificates==totalNumberOfCompleteChains)) && print -P -n "%F{green}" || print -P -n "%F{red}"
        print -P "$1: $totalNumberOfCompleteChains/$totalNumberOfCertificates complete chains%F{none}"
}

#
# Main
#
# parse comand line arguments
#
checkDirectory=""
while getopts ":d:" opt
do
    case ${opt} in
        d )
            checkDirectory="${OPTARG}"
            ;;
        ":" )
            echo "option -${OPTARG} requires an argument"
            exit 1
            ;;
        \? )
            echo "Usage: `basename $0` [-d <certificate directory>]"
            exit 0
            ;;
    esac
done
shift $((OPTIND -1))

#
# if there is no specific directory to check then try to find and verify all
# directories with trusted certificates
#
if [ -n "$checkDirectory" ]
then
    initializeArrays
    loadChainCertificates "$checkDirectory"
    verifyCertificateChains "$checkDirectory"
else
    #set -e
    for dir in config/*/certificates/trust
    do
        #set +e
        initializeArrays
        loadChainCertificates "$dir"
        verifyCertificateChains "$dir"
    done
fi
