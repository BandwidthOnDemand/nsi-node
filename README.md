# NSI-node

NSI-node is a [Helm](https://helm.sh/) chart to install a configurable
combination of the NSI aggregator
[Safnari](https://github.com/BandwidthOnDemand/nsi-safnari) and
[PCE](https://github.com/BandwidthOnDemand/nsi-pce), [Document Distribution
Service](https://github.com/BandwidthOnDemand/nsi-dds) and network service
agent [OpenNSA](https://github.com/BandwidthOnDemand/nsi-opennsa), together
with a [Postgresql](https://bitnami.com/stack/postgresql/helm) database and
[Envoy](https://github.com/BandwidthOnDemand/nsi-envoy) proxy for access
authorisation.

**Table of Contents**

* [Installation](#installation)
  * [Helm chart repositories](#helm-chart-repositories)
  * [NSI\-node chart](#nsi-node-chart)
    * [Local copy](#local-copy)
    * [Configuration repository](#configuration-repository)
* [Configuration](#configuration)
  * [Folder layout](#folder-layout)
  * [Enable/disable applications](#enabledisable-applications)
  * [Certificates](#certificates)
  * [Configuration files](#configuration-files)
    * [nsi\-safnari](#nsi-safnari)
    * [nsi\-dds](#nsi-dds)
    * [nsi\-pce](#nsi-pce)
    * [nsi\-opennsa](#nsi-opennsa)
    * [nsi\-envoy](#nsi-envoy)
* [Deploy](#deploy)
  * [Check certificates and chains](#check-certificates-and-chains)
  * [Create chart configuration](#create-chart-configuration)
  * [Install or upgrade deployment](#install-or-upgrade-deployment)

## Installation

### Helm chart repositories

For Safnari, PCE, DDS, OpenNSA, Envoy and nsi-node add the NSI-node Helm chart
repository and for Postgresql add the Bitnami repository and update information
of available charts locally for the just added chart repositories:

```shell
helm repo add nsi-node https://bandwidthondemand.github.io/nsi-node/
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update
```

### NSI-node chart

There are several ways to use the NSI-node chart, for example use a local copy
of the chart, or if you want to maintain your NSI-node configuration in a
separate repository you can add the NSI-node chart as a Git submodule. But any
other way that suites you purpose will work as well of course. 

#### Local copy

Clone the NSI-node repository and add your configuration to the config/ folder:

```shell
git clone https://github.com/BandwidthOnDemand/nsi-node.git
```

Changes to the config/ and chart/ folders are ignored by git.

#### Configuration repository

Create a new Git repository for you configuration and add the NSI-node chart as
a git submodule. If you for example use the GitLab auto deploy capabilities you
want the submodule to reside inside the charts folder, but any folder will do.

```shell
mkdir nsi-node-example
cd nsi-node-example
git init
git submodule add https://github.com/BandwidthOnDemand/nsi-node.git charts/nsi-node-example
```

To include the latest changes to the NSI-node chart update the submodule:

```shell
git submodule update --remote
```

To always see the changes to submodules in a diff change your git
configuration:

```shell
git config --global diff.submodule
```

## Configuration

### Folder layout

Every chart has its own sub folder in the config folder:

```ignorelang
config
├── nsi-dds
├── nsi-envoy
├── nsi-opennsa
├── nsi-pce
└── nsi-safnari
```

And every chart config has a templates sub folder and a certificates sub folder
for the key and trust certificates, for example nsi-safnari:

```ignorelang
config
└── nsi-safnari
    ├── certificates
    │   ├── key
    │   └── trust
    └── templates
```
### Enable/disable applications

Every application can be enabled or disabled by setting the enabled value in
values.yaml for the corresponding chart condition:

```yaml
nsi-safnari:
  enabled: true
```

Frequently used combinations of applications are Safnari + PCE + DDS +
Postgresql or OpenNSA + Postgresql. One single database can be used by multiple
applications.

### Certificates

The type of the certificate is determined by the filename suffix, private keys
have suffix `.key`, leaf certificates have suffix `.crt` and root and
intermediate certificates have suffix `.chain`. Private key and corresponding
certificate and chain that identify the deployed application are placed in the
`key` folder, certificates with their chains of the application trusted peers
are placed in the `trust` folder. It is assumed that any file contains at most
one certificate.

If NSI-node is deployed using a CI/CD tool the application private keys can be
stored as CI file variables and copied to the correct `key` folder from the CI
deploy script.

### Configuration files

The per-application set of configuration files is placed in the `templates`
folder. Configuration file examples can be found in the `examples` folder of
the NSI-node chart.

#### nsi-safnari

```ignorelang
config
└── nsi-safnari
    └── templates
        ├── config-overrides.conf
        ├── create-postgres-db.sh
        ├── envoy-cluster.yaml
        └── envoy-filter_chain_match.yaml
```

At least the following should be configured:

* **config-overrides.conf**
  * **db.default.url**
    * Update the postgresql service name and namespace.
  * **safnari.nsa.id**
    * The NSA ID of your Safnari deployment.
  * **safnari.nsa.name**
    * The name of your Safnari deployment.
  * **safnari.dds.url**
    * Update the dds service name and namespace.
  * **pce.endpoint**
    * Update the pce service name and namespace.
  * **nsi.base.url**
    * Base URL of your Safnari deployment, used to construct correct URL's.
* **envoy-filter_chain_match.yaml**
  * **server_names**
    * Change to the hostname used for you Safnari deployment.
  * **default_host_for_http_10**
    * Idem ditto.
* **envoy-cluster.yaml**
  * **address**
    * Set to the nsi-safnari service name in the namespace you deployed NSI-node.

#### nsi-dds

```ignorelang
config
└── nsi-dds
    └── templates
        ├── dds.xml
        ├── envoy-cluster.yaml
        ├── envoy-filter_chain_match.yaml
        ├── log4j.xml
        └── logging.properties
```

At least the following should be configured:

* **dds.xml**
  * **nsaId**
    * ID of your local NSA.
  * **baseURL**
    * Base URL of your DDS deployment, used to construct correct URL's. 
  * **peerURL**
    * One or more URL's for DDS subscriptions and NSA discovery documents to fetch.
* **envoy-filter_chain_match.yaml**
  * **server_names**
    * Change to the hostname used for you DDS deployment.
  * **default_host_for_http_10**
    * Idem ditto.
* **envoy-cluster.yaml**
  * **address**
    * Set to the nsi-dds service name in the namespace you deployed NSI-node.

#### nsi-pce

```ignorelang
config
└── nsi-pce
    └── templates
        ├── beans.xml
        ├── http.json
        ├── log4j.xml
        ├── logging.properties
        └── topology-dds.xml
```

At least the following should be configured:

* **topology-dds.xml**
  * **ddsURL**
    * Update the dds service name and namespace.

#### nsi-opennsa

```ignorelang
config
└── nsi-opennsa
    ├── backends
    └── templates
        ├── create-postgres-db.sh
        ├── envoy-cluster.yaml
        ├── envoy-filter_chain_match.yaml
        ├── opennsa.conf
        ├── opennsa.nrm
        └── opennsa.tac
```

The needed backend(s) can be copied to the `backends` folder.

At least the following should be configured:

* **envoy-filter_chain_match.yaml**
  * **server_names**
    * Change to the hostname used for you OpenNSA deployment.
  * **default_host_for_http_10**
    * Idem ditto.
* **envoy-cluster.yaml**
  * **address**
    * Set to the nsi-opennsa service name in the namespace you deployed NSI-node.
* **opennsa.conf**
  * **domain**
    * The domain part of the NSA ID this OpenNSA deployment is responsible of.
  * **host**
    * Hostname for your OpenNSA deployment.
  * **base_url**
    * In a setup with TLS disabled behind a proxy like envoy as used by NSI-node, set this to the outside base URL of this OpenNSA.
  * **dbhost**
    * Update the postgresql service name and namespace.
  * **[dud:topology]**
    * Update the backend module and corresponding topology.
* **opennsa.nrm**
  * Update the network resource map to reflect the STP's your network is exposing.

#### nsi-envoy

```ignorelang
config
└── nsi-envoy
    └── templates
        └── envoy-head.yaml
```

Nothing should be configured here.

## Deploy

Deploying a NSI node roughly involves the following steps:

1. create NSI-node local copy or Git repository with NSI node as submodule, and add you local deployment configuration, certifiates and keys
2. check the trust certificates and chains with the `check-certificates.sh` script
3. create a NSI-node chart configuration with the `create-config.sh` script
4. deploy the NSI-node chart with Helm

### Check certificates and chains

The  `check-certificates.sh` script checks for every found certificate, files
with suffix `.crt`, if a complete chain can be found using the files witch
suffix `.chain`. It will also check if no certificates or parts of a chain are
expired. By default all trust folders of all applications are checked. The `-d`
switch can be ussed to check just one trust folder or a set of certificates in
an alternate location.

### Create chart configuration

The `create-config.sh` script creates a NSI-node chart configuration.Additional
debug output can be enabled with the `-d` switch. By default it will use the
certificates and templates from the `config` folder, an alternate config folder
location can be specified with the `-c` switch. Creating a chart config
involves the following steps:

* download all library charts
* install certificates, chains and keys in a format suitable for the application deployed
* copy the application specific configuration files to the library charts
* create envoy configuration
  * use admin interface configuration from `envoy-head.yaml`
  * add filter and cluster for nsi-safnari, nsi-dds and nsi-opennsa from `envoy-filter_chain_match.yaml` and `envoy-cluster.yaml`
  * per application add SPKI of all trusted leaf certificates to filter
  * add application certificate, chain and key from `key` folder
  * create chain of acceptable CA's by combining the per application trusted chains
* add nsi-safnari and nsi-opennsa `create-postgres-db.sh` script to postrgresql docker-entrypoint-initdb.d folder

### Install or upgrade deployment

There are two secrets that should be created before the NSI-node chart is
installed. These secrets are stored in a per deployment specific K8S secret
that uses a name based on the NSI-node chart deployment name. The
POSTGRES_PASSWORD must be passed on the helm command line, not only for the
first install but also when you upgrade your NSI-node helm deployment.

```shell
kubectl create secret generic example-nsi-node-secret \
        --from-literal=POSTGRES_PASSWORD="`head -c 33 /dev/urandom | base64`" \
        --from-literal=SAFNARI_APPLICATION_SECRET="`head -c 33 /dev/urandom | base64`"
POSTGRES_PASSWORD=`kubectl get secret example-nsi-node-secret \
        -o jsonpath="{.data.POSTGRES_PASSWORD}" | base64 --decode`
./create-config.sh
helm upgrade \
        --install \
        --set postgresql.postgresqlPassword=$POSTGRES_PASSWORD \
        example-nsi-node .
```

While upgrading the configuration of an exiting NSI-node deployment you can use
the above commands as well but skip the creation of the secret.
