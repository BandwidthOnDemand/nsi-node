# NSI-node

NSI-node is a [Helm](https://helm.sh/) chart to install a configurable
combination of the NSI aggregator
[Safnari](https://github.com/BandwidthOnDemand/nsi-safnari) and
[PCE](https://github.com/BandwidthOnDemand/nsi-pce), [Document Distribution
Service](https://github.com/BandwidthOnDemand/nsi-dds), network service agent
[OpenNSA](https://github.com/BandwidthOnDemand/nsi-opennsa), ultimate provide agent
[SuPA](https://github.com/workfloworchestrator/SuPA) in combination with NSI SOAP/gRPC proxy
[PolyNSI](https://github.com/workfloworchestrator/PolyNSI), and
[NSI requester client](https://github.com/BandwidthOnDemand/nsi-requester), together with a
[Postgresql](https://bitnami.com/stack/postgresql/helm) database and
[Envoy](https://github.com/BandwidthOnDemand/nsi-envoy) proxy for access
authorisation, optionally with the
[NSI Authentication Server](https://github.com/workfloworchestrator/nsi-auth)
as an external authorisation endpoint for ingress controllers and gateways.

The charts for the newer ANA automation components — `nsi-orchestrator`,
`nsi-orchestrator-ui`, `nsi-dds-proxy`, `nsi-aggregator-proxy`, `nsi-mgmt-info`,
`nsi-aura` and `ana-automation-ui` — are published alongside these but are not
part of the NSI-node umbrella chart; they are deployed on their own. See
[Helm chart repositories](#helm-chart-repositories) for the full inventory.

![NSI-node overview image](docs/nsi-node-overview.png)

**Table of Contents**

* [How it works in a nutshell](#how-it-works-in-a-nutshell)
  * [Distributed Document Service (DDS)](#distributed-document-service-dds)
  * [Patch Computation Element (PCE)](#patch-computation-element-pce)
  * [Safnari NSI Aggregator](#safnari-nsi-aggregator)
  * [OpenNSA NSI uPA](#opennsa-nsi-upa)
  * [SuPA NSI uPA and PolyNSI](#supa-nsi-upa-and-polynsi)
  * [NSI Requester Web GUI](#nsi-requester-web-gui)
  * [PostgreSQL database](#postgresql-database)
  * [Envoy proxy](#envoy-proxy)
* [Installation](#installation)
  * [Helm chart repositories](#helm-chart-repositories)
    * [The frozen nsi\-node chart repository](#the-frozen-nsi-node-chart-repository)
  * [Publishing a chart](#publishing-a-chart)
  * [NSI\-node chart](#nsi-node-chart)
  * [Helm deployment values](#helm-deployment-values)
* [Configuration](#configuration)
  * [Folder layout](#folder-layout)
  * [Enable/disable applications](#enabledisable-applications)
  * [Certificates](#certificates)
  * [Application configuration files](#application-configuration-files)
  * [Expose node to the outside world](#expose-node-to-the-outside-world)
* [Deploy](#deploy)
  * [Check certificates and chains](#check-certificates-and-chains)
  * [Create chart configuration](#create-chart-configuration)
  * [Create a Java trust store](#create-a-java-trust-store)
  * [Install or upgrade deployment](#install-or-upgrade-deployment)
* [Debug](#debug)
  * [Envoy proxy](#envoy-proxy-1)

## How it works in a nutshell

A terse description on how an automated GOLE NSI node functions can be found
below. For more background information please have a look at the following
documents:

* [Network Services Framework v2.0](https://www.ogf.org/documents/GFD.213.pdf) 
* [Network Service Interface Signaling and Path Finding](https://www.ogf.org/documents/GFD.217.pdf)
* [Network Service Agent Description](https://www.ogf.org/documents/GFD.220.pdf)
* [NSI Authentication and Authorization](http://www.ogf.org/documents/GFD.232.pdf)
* [Applying Policy in the NSI Environment](https://www.ogf.org/documents/GFD.233.pdf)
* [Network Service Interface Signaling and Path Finding](http://www.ogf.org/documents/GFD.234.pdf)
* [NSI Connection Service v2.1](http://www.ogf.org/documents/GFD.237.pdf)
* [Error Handling in NSI CS 2.1](http://www.ogf.org/documents/GFD.235.pdf)
* [Network Service Interface Document Distribution Service](http://www.ogf.org/documents/GFD.236.pdf)

### Distributed Document Service (DDS)

The DDS serves as a central storage for all documents needed in a NSI
infrastructure. Currently two types of documents are hosted: discovery
documents of type  `vnd.ogf.nsi.nsa.v1+xml` and topology documents of type
`vnd.ogf.nsi.topology.v2+xml`. The DDS is configured to retrieve these
documents from Network Service Agents (NSA) and will periodically check for
updates. To reduce the data transport and processing overhead the
`If-Modified-Since` HTTP header is used during update checks. When a discovery
document is fetched the DDS will subsequently also automatically fetch all
topology documents mentioned in the discovery document.

The DDS also has a publish/subscribe interface to synchronise its content with
other DDS. This allows for redundancy, by having the same document fetched by
multiple DDS, and not every DDS needs to fetch every document itself, allowing
the setup of geographical or administrative zones.

A GUI is available at https://dds.example.domain/dds/portal to view the
following:

* Server Configuration: the NSA id and configured documents and subscriptions
* Subscription: from other DDS
* My Subscriptions: to other DDS
* Documents: all discovery and topology documents present at this DDS with the ability to view the contents

### Patch Computation Element (PCE)

The PCE fetches all topology documents present at the DDS to build a global
view of network connectivity. It does this by matching Service Termination
Points (STP) from all topology documents to form Service Demarcation Points
(SDP) where two topologies are connected. The PCE periodically checks the DDS
for updated documents and updates the connectivity graph as needed. The PCE
accepts path computation requests to find a path between a set of STP. It will
first check if the STP exist and then calculate the shortest path between them.
On success the PCE will return an ordered list of path segments, each segment
described by two STP in the same network, that together form a string of cross
connects that implement the requested connectivity.

Besides the STP connectivity graph the PCE also constructs a control plane
connectivity graph by matching the peersWith attributes from all discovery
documents. This allows for routing of NSI requests via other NSA if no direct
control plane connectivity exists.

### Safnari NSI Aggregator

The Safnari NSI Aggregator receives NSI requests, sends back a confirmation of
receipt in the same control plan connection, and in case of a synchronous
request will also send back the result in that same first connection. In case
of an asynchronous request the result is returned to the reply-to address in
the request after completion. In case of a reservation request the aggregator
asks the PCE to calculate a path, sends per path segment requests to child NSA,
receives the replies from child NSA and returns an aggregated state to the
requester. The discovery document of this NSA is located at
https://safnari.example.domain/nsa-discovery.

A GUI is available at https://safnari.example.domain that shows an overview of
the currently present connections. Per connections the overall state is shown
together with a complete log of every synchronous or asynchronous NSI message
received and sent.

### OpenNSA NSI uPA

OpenNSA is a NSI ultimate Provider Agent (uPA) that interfaces between NSI and
the local network. The pluggable backends allow for interfacing towards a local
Network Resource Manager (NRM) or talk directly to a local network element.
OpenNSA also has partial aggregation support that allows for hosting
multiple network topologies on a single OpenNSA instance. The discovery
document of this NSA is located at
https://opennsa.example.domain/NSI/discovery.xml.

OpenNSA uses the pluggable backend system to interface to the local network
resources. The OpenNSA topology configuration file maps STP and SDP to local
port identifiers and VLAN ranges.

### SuPA NSI uPA and PolyNSI

SuPA is a complete new NSI ultimate provider agent that uses modern design
patterns and implements the latest NSI protocol specification. It offers a gRPC
based version of the NSI protocol and is accompanied by PolyNSI that acts as a
NSI SOAP/gRPC proxy to interface with existing SOAP based NSA. It also has a
pluggable backend mechanism and offers both manual and automated topology
generation. The discovery document of this NSA is located at
https://supa.example.domain/NSI/discovery.

### NSI Requester Web GUI

The NSI Requester Web GUI is a NSI protocol debug tool that can be used to
construct and send NSI messages via a web GUI. Per message sent it shows the
message sent together with all synchronous and asynchronous messages received.
Support is available for reserve, commit, provision, release and terminate
primitives, as well as querying all connections and events.

### PostgreSQL database

A single PostgreSQL database is used to store the databases for Safnari and
OpenNSA. The same username and password is used by both.

The per-application databases are created at first start from the
`create-postgres-db.sh` scripts that `create-config.sh` collects into
`charts/postgresql/initdb.d/`. `deploy.sh` turns that folder into a ConfigMap
named `postgresql-init-scripts`, which the chart mounts via
`postgresql.primary.initdb.scriptsConfigMap`.

### Envoy proxy

The Envoy proxy is the interface between the Kubernetes ingress or service
loadBalancer IP and the Kubernetes services in front of DDS, Safnari, OpenNSA
and NSI Requester. All TLS connections are terminated on the proxy. A per
application list of certificate Subject Public Key Information hashes is
maintained to check if a connecting client is allowed access or not.
Communication inside the cluster is plain HTTP.

For personal access to the GUI, API or documents served by all applications a
personal certificate needs to be configured per application.

## Installation

### Helm chart repositories

Charts are published as OCI artifacts to the GitHub Container Registry of the
organisation that owns the source repository. There is no `helm repo add` step:
an OCI reference is used directly wherever a chart name would otherwise go.

| Registry | Charts |
| --- | --- |
| `oci://ghcr.io/bandwidthondemand/charts` | `nsi-dds`, `nsi-pce`, `nsi-safnari`, `nsi-envoy`, `nsi-opennsa`, `nsi-requester` |
| `oci://ghcr.io/workfloworchestrator/charts` | `ana-automation-ui`, `nsi-aggregator-proxy`, `nsi-aura`, `nsi-auth`, `nsi-dds-proxy`, `nsi-mgmt-info`, `nsi-orchestrator`, `nsi-orchestrator-ui`, `polynsi`, `supa` |

Inspect and install directly:

```shell
helm show chart oci://ghcr.io/bandwidthondemand/charts/nsi-dds --version <version>
helm upgrade --install nsi-dds oci://ghcr.io/bandwidthondemand/charts/nsi-dds --version <version>
```

In a `Chart.yaml` dependency the repository is the namespace *without* the chart
name. The `"@nsi-node"` alias form used by older umbrella charts does not work
for OCI and must be replaced with the full URL:

```yaml
dependencies:
  - name: nsi-dds
    version: "<version>"
    repository: "oci://ghcr.io/bandwidthondemand/charts"
    condition: nsi-dds.enabled
```

Postgresql still comes from a classic HTTP repository:

```shell
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update
```

#### The frozen `nsi-node` chart repository

`https://bandwidthondemand.github.io/nsi-node/` served every chart until
2026-08-20 and is **frozen**, not removed: the index and its `.tgz` files stay
online indefinitely so existing pinned versions keep resolving. It receives no
new versions. Anything released after the freeze date exists only in the
registries above.

Note that the `nsi-node` chart itself was never published there — it is used via
a local copy or a Git submodule, as described below.

### Publishing a chart

Publishing is automated. Each source repository has a `.github/workflows/chart.yml`
that packages its chart and pushes it to its organisation's namespace when a
semver git tag is pushed. There is no manual `helm package`, no copying of
`.tgz` files, and no index to regenerate.

**The chart version is the git tag.** For the application charts it is also the
`appVersion`, so one number describes both the chart and the application it
deploys:

```shell
helm package chart --version "$TAG" --app-version "$TAG"
```

The `version` and `appVersion` fields in each `Chart.yaml` are placeholders
(`0.0.0`) and are not maintained by hand. `0.0.0` sorts below every real release
and names a container image tag that does not exist, so a chart built without
the injected version fails at image pull rather than deploying something
unexpected.

To release a chart, tag the source repository:

```shell
git tag <version> && git push origin <version>
```

Because there is only one version number, a chart-only fix still needs its own
patch tag. That also rebuilds the container image, so a "chart-only" release can
pick up newer base-image layers — worth knowing before releasing one casually.

Three charts are exceptions: `nsi-envoy`, `nsi-opennsa` and `nsi-requester`
package third-party applications, so their `appVersion` names an upstream
release (`1.20.1`, `opennsa-3.0.2-1c76f34-1`) that has nothing to do with the
chart version. For those the tag sets the chart version only, and `appVersion`
stays a hand-maintained pin of the upstream image.

### NSI-node chart

There are several ways to use the NSI-node chart, for example use a local copy
of the chart, or if you want to maintain your NSI-node configuration in a
separate repository you can add the NSI-node chart as a Git submodule. But any
other way that suites you purpose will work as well of course. 

`Chart.yaml` resolves its subcharts from the OCI registries, so
`helm dependency update` needs no `helm repo add` for them. Only the Postgresql
dependency still comes from a classic repository, so the Bitnami repo does have
to be added first.

#### Local copy

Clone the NSI-node repository and add your configuration to the config/ folder:

```shell
git clone https://github.com/BandwidthOnDemand/nsi-node.git
```

The `config/` and `charts/` folders are ignored by git, and so are `values.yaml`
and `Chart.lock`. Your deployment configuration therefore lives outside version
control in a plain clone — if you want it versioned, use the configuration
repository layout described below.

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
git config --global diff.submodule log
```

### Helm deployment values

The NSI-node chart and its application library charts can be configured by editing the `Chart.yaml` and `values.yaml` files. A version with reasonable defaults of the latter file can be found in the examples folder and should be copied to the top folder of the checked out version of the chart.

Note that `examples/values.yaml.example` predates several of the charts it is
meant to seed — it has no `nsi-auth` section and no Bitnami legacy image pins —
so treat it as a starting point rather than a current reference.

## Configuration

### Folder layout

Every chart has its own sub folder in the config folder:

```ignorelang
config
├── nsi-dds
├── nsi-envoy
├── nsi-opennsa
├── nsi-pce
├── nsi-requester
├── nsi-safnari
├── polynsi
└── supa
```

`supa` is configured inline in `values.yaml` rather than from files, so its
folder holds only an empty `certificates/key` and `templates`.

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

The chart conditions are `nsi-dds`, `nsi-pce`, `nsi-safnari`, `nsi-envoy`,
`nsi-opennsa`, `nsi-requester`, `supa`, `polynsi`, `nsi-auth` and `postgresql`.

Frequently used combinations of applications are Safnari + PCE + DDS +
Postgresql or OpenNSA + Postgresql. One single database can be used by multiple
applications.

Note that Helm ignores a condition it cannot resolve, so **omitting a stanza
enables that component** rather than leaving it out. `examples/values.yaml.example`
carries all ten, but if you write your own `values.yaml` from scratch, an
component you simply never mention will be deployed. `nsi-auth` is the easiest
one to get wrong, since a plain NSI node has no use for it:

```yaml
nsi-auth:
  enabled: false
```

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

### Application configuration files

The per-application set of configuration files is placed in the `templates`
folder. Configuration file examples can be found in the `examples` folder of
the NSI-node chart.

#### nsi-safnari

```ignorelang
config
└── nsi-safnari
    ├── certificates
    │   ├── key
    │   └── trust
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
    ├── certificates
    │   ├── key
    │   └── trust
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
    ├── certificates
    │   ├── key
    │   └── trust
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
    ├── certificates
    │   ├── key
    │   └── trust
    ├── credentials
    └── templates
        ├── create-postgres-db.sh
        ├── envoy-cluster.yaml
        ├── envoy-filter_chain_match.yaml
        ├── opennsa.conf
        ├── *.nrm
        └── opennsa.tac
```

The needed backend(s) can be copied to the `backends` folder and will be
available inside the container under `/backends`.

Any optional credentials needed by a backend can be added to the `credentials` folder
and will be available inside the container directly under `/config`

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
* ***.nrm**
  * Add at least one network resource map to reflect the STP's in the topology you are exposing.
    Any filename with suffix `.nrm` will be included.

#### nsi-requester

```ignorelang
config
└── nsi-requester
    ├── certificates
    │   ├── key
    │   └── trust
    └── templates
        ├── config-overrides.conf
        ├── envoy-cluster.yaml
        └── envoy-filter_chain_match.yaml
```

* **config-overrides.conf**
  * Play configuration overriding `application.conf`. It takes the application
    secret from the `NSI_REQUESTER_APPLICATION_SECRET` environment variable that
    `deploy.sh` puts in the deployment secret, and configures the WS client key
    and trust stores for two-way TLS against
    `/config/nsi-requester-keystore.jks` and the matching trust store.

#### polynsi

```ignorelang
config
└── polynsi
    ├── certificates
    │   ├── key
    │   └── trust
    └── templates
        ├── application.properties
        ├── envoy-cluster.yaml
        └── envoy-filter_chain_match.yaml
```

Please refer to the
[PolyNSI configuration documentation](https://github.com/workfloworchestrator/PolyNSI#configuration)
for more information.

#### supa

SuPA is configured with an inline `supa.env` in the nsi-node `values.yaml` configuration.
Please refer to the
[SuPA configuration documentation](https://workfloworchestrator.org/SuPA/index.html)
for more information.

#### nsi-envoy

```ignorelang
config
└── nsi-envoy
    └── templates
        └── envoy-head.yaml
```

Nothing should be configured here.

### Expose node to the outside world

The stack uses virtual hostname based routing of the traffic through the Envoy
proxy. There are multiple ways of exposing your NSI-node stack to the outside
world, two of them are described below.

#### With k8s LoadBalancer IP

The easiest way probably is to specify the external IP address as
`LoadBalancer` `ipAddress` when publishing the nsi-envoy service. For an Azure
deployement edit the `nsi-envoy` section in `values.yaml` to look like
configuration snippet below. Please consult the cloud providers documentation

```yaml
nsi-envoy:
  enabled: true

  service:
    type: LoadBalancer
    ipAddress: "1.2.3.4"
    port: 443
    annotations:
      service.beta.kubernetes.io/azure-load-balancer-internal: "true"

  ingress:
    enabled: false
```

#### With k8s ingress

Another way is to have your `ingress` route the set of virtual hostnames to
your `nsi-envoy` service. This example uses an HAProxy based ingress, consult
your cloud providers documentation for other ingresses like NGINX.

```yaml
nsi-envoy:
  enabled: true

  service:
    port: 443
    type: ClusterIP

  ingress:
    enabled: true
    className: haproxy
    annotations:
      haproxy.kubernetes.io/ssl-passthrough: "true"
    hosts:
      - host: dds.example.domain
        paths:
        - path: /
          pathType: Prefix
      - host: safnari.example.domain
        paths:
        - path: /
          pathType: Prefix
      - host: opennsa.example.domain
        paths:
        - path: /
          pathType: Prefix
```

The backend service and port are not configured here — the template always
points every rule at the `nsi-envoy` service on `service.port`. Older versions
of this document showed `backend.serviceName`/`servicePort` under each path;
those keys were always ignored, and the field names themselves belong to the
`extensions/v1beta1` Ingress removed in Kubernetes 1.22.

The template selects the Ingress `apiVersion` and backend shape from the
cluster version, so `className` and `pathType` are used on 1.19+ and silently
dropped on older clusters.

## Deploy

Deploying a NSI node roughly involves the following steps:

1. create NSI-node local copy or Git repository with NSI node as submodule, and add you local deployment configuration, certifiates and keys
2. check the trust certificates and chains with the `check-certificates.sh` script
3. create a NSI-node chart configuration with the `create-config.sh` script
4. if an application needs a Java trust store, create it with the `create-truststore.sh` script
5. deploy the NSI-node chart with Helm

The scripts need `zsh` (`create-config.sh` and `create-truststore.sh` are zsh,
and `deploy.sh` invokes `create-config.sh` through it), plus `yq` for reading
`values.yaml`, and `keytool` and `openssl` for the trust store.

### Check certificates and chains

The  `check-certificates.sh` script checks for every found certificate, files
with suffix `.crt`, if a complete chain can be found using the files with
suffix `.chain`. It will also check if no certificates or parts of a chain are
expired. By default all trust folders of all applications are checked. The `-d`
switch can be ussed to check just one trust folder or a set of certificates in
an alternate location.

### Create chart configuration

The `create-config.sh` script creates a NSI-node chart configuration. Additional
debug output can be enabled with the `-d` switch. By default it will use the
certificates and templates from the `config` folder, an alternate config folder
location can be specified with the `-c` switch. Creating a chart config
involves the following steps:

* download the library charts with `helm dependency update`, then unpack them again for the applications that need a generated config folder
* install certificates, chains and keys in a format suitable for the application deployed
* copy the application specific configuration files to the library charts
* create envoy configuration
  * use admin interface configuration from `envoy-head.yaml`
  * add filter and cluster for nsi-dds, nsi-safnari, nsi-opennsa, nsi-requester and polynsi from `envoy-filter_chain_match.yaml` and `envoy-cluster.yaml`
  * per application add SPKI of all trusted leaf certificates to filter
  * add application certificate, chain and key from `key` folder
  * create chain of acceptable CA's by combining the per application trusted chains
* add nsi-safnari and nsi-opennsa `create-postgres-db.sh` script to postrgresql docker-entrypoint-initdb.d folder

### Create a Java trust store

The `create-truststore.sh` script builds a JKS trust store for a single
application from the certificates and chains in its `trust` folder, and writes
it to `charts/<app>/<app>-truststore.jks`. Additional debug output can be
enabled with the `-d` switch, and an alternate config folder with `-c`.

```shell
./create-truststore.sh -c "config_folder" nsi-safnari
```

### Install or upgrade deployment

The `deploy.sh` script runs the `create-config.sh` script mentioned above, then
creates the Kubernetes objects the chart expects before installing it:

* a per deployment secret named `<deployment name>-secret`, holding
  `NSI_REQUESTER_APPLICATION_SECRET` and `SAFNARI_APPLICATION_SECRET` (both
  freshly generated on every run) and `POSTGRES_PASSWORD`
* a ConfigMap named `postgresql-init-scripts`, built from
  `charts/postgresql/initdb.d/*`

It then runs `helm upgrade --install --cleanup-on-fail --atomic --wait`, so a
failed deploy is rolled back rather than left half-applied.

The postgres password is not generated; it must be passed in through the
`POSTGRES_PASSWORD` shell variable, which is used both for the secret and for
`--set postgresql.auth.password`. A CI based deployment can store the postgres
password as a CI secret and have it passed to the deploy script when the deploy
pipeline is being run.

```shell
POSTGRES_PASSWORD="secret password" ./deploy.sh -d "deployment_name" -n "namespace" -c "config_folder"
```

Note that the application secrets are regenerated on every run, so each deploy
restarts the pods that consume them.

While upgrading the configuration of an exiting NSI-node deployment you can use
the above command as well.

## Debug

Of course all the usual k8s tools will work to debug your deployment, usually
this suffices.

### Envoy proxy

An easy way to tune the log detail of a running Envoy proxy is to set the log
level through the admin interface. First forward the admin interface port to
localhost:

```shell
port-forward <nsi-envoy pod name> 8081:8081
```

Have a look at the available loggers and their configured level:

```shell
curl --request POST "http://localhost:8081/logging"
```

Change log level to debug on all loggers:

```shell
curl --request POST "http://localhost:8081/logging?level=debug"
```

Or only set a single logger to level debug. Suggested is to start set loggers
`conn_handler` and `router` to level debug:

```shell
curl --request POST "http://localhost:8081/logging?conn_handler=debug"
curl --request POST "http://localhost:8081/logging?router=debug"
```
