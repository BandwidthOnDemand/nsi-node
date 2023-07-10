#!/bin/sh
#
# parse command line options
#
while getopts ":d:n:c:" opt
do
    case ${opt} in
        d )
            HELM_DEPLOYMENT_NAME="${OPTARG}"
            ;;
        n )
            NAMESPACE="${OPTARG}"
            ;;
        c )
            CONFIG_FOLDER="${OPTARG}"
            ;;
        ":" )
            log ERROR "option -${OPTARG} requires an argument"
            exit 1
            ;;
        \? )
            echo "Usage: `basename $0` --d <helm_deployment_name> --n <kubernetes namespace> --c <nsi node config folder>"
            exit 1
            ;;
    esac
done
shift $((OPTIND -1))
if test -z "$HELM_DEPLOYMENT_NAME" -o -z "$NAMESPACE" -o -z "$CONFIG_FOLDER"
then
    echo "ERROR: must set deployment name AND namespace AND config folder"
    exit 1
fi
#
# create configuration
#
zsh create-config.sh -c "${CONFIG_FOLDER}"
#
# create needed secrets
#
if test -z "${POSTGRES_PASSWORD}"
then
    echo "ERROR: you must set postgresql password through POSTGRES_PASSWORD shell variable"
    exit 1
fi
kubectl delete secret --ignore-not-found "${HELM_DEPLOYMENT_NAME}-secret"
kubectl create secret generic "${HELM_DEPLOYMENT_NAME}-secret" \
    --from-literal=NSI_REQUESTER_APPLICATION_SECRET="`head -c 33 /dev/urandom | base64`" \
    --from-literal=SAFNARI_APPLICATION_SECRET="`head -c 33 /dev/urandom | base64`" \
    --from-literal=POSTGRES_PASSWORD="${POSTGRES_PASSWORD}"
#
# create configmap with postgresql init scripts
#
kubectl delete configmaps --ignore-not-found postgresql-init-scripts
kubectl create configmap postgresql-init-scripts `echo charts/postgresql/initdb.d/* | sed -e 's/^/ /' -e 's/ / --from-file /g'`
#
# install/upgrade nsi-node deployment
#
helm upgrade --namespace "${NAMESPACE}" --install --cleanup-on-fail --atomic --wait --set postgresql.auth.password="${POSTGRES_PASSWORD}" "${HELM_DEPLOYMENT_NAME}" .
