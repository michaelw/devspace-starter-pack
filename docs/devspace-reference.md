# DevSpace Reference

## Profiles

| Profile | Description | Components |
|---------|-------------|------------|
| `local-network` | Core local networking | MetalLB, Istio, Gateway API |
| `local-dns` | Local DNS integration | External DNS, CoreDNS, etcd |
| `local-certs` | Local certificate management | cert-manager, trust-manager, reflector |
| `local-aux` | Local auxiliary services | Reloader |
| `with-test` | Shared test applications | httpbin plus provider-specific routes |
| `gke-network` | GKE networking | GKE Gateway API without Istio or MetalLB |
| `gke-dns` | GKE DNS integration | Cloud DNS-backed external-dns with Workload Identity |
| `gke-certs` | GKE certificate management | cert-manager, trust-manager, reflector, starter-pack CA |
| `with-o11y` | Shared observability base | Prometheus, OpenTelemetry Collector, Jaeger |
| `local-o11y` | Local observability overlay | metrics-server, local Jaeger route, Istio metrics monitors |
| `gke-o11y` | GKE observability overlay | GKE Prometheus overrides, GKE Jaeger route, IAP policies |
| `o11y-grafana` | Grafana UI | Grafana, route, datasources, dashboards |
| `o11y-addons` | Extended observability | Alloy, Loki, Tempo, Grafana datasource ConfigMaps |
| `local-psql` | PostgreSQL database | PostgreSQL with persistence |
| `local-redis` | Redis cache | Redis with persistence |
| `local-es` | ElasticSearch | Single-node ElasticSearch |

Base local and GKE infrastructure profiles activate from the active kube context. Test services use
the same pattern: select `with-test`, and DevSpace adds the local Istio routes or the GKE Gateway
routes from the context. Observability also uses provider overlays: `with-o11y` is the shared base,
then `local-o11y` or `gke-o11y` activates from the context. Do not persist `CLUSTER_PROVIDER`; use it
only as an explicit setup/test selector.

## Commands

List all commands:

```bash
devspace list commands
```

Common commands:

```bash
devspace run check-tools
devspace run ensure-cluster
devspace --var CLUSTER_PROVIDER=gke run ensure-cluster
devspace run test-install
devspace run print-cluster-env
devspace run update-cluster-dns
devspace run reset-cluster-dns
devspace run import-root-ca
devspace run gke-gateway-resources
devspace run gke-dev-registry-info
devspace run port-forward-otel
```

## Tool Inventory

`devspace run check-tools` is a fast local preflight. It checks commands on `PATH` for the active
kube context and does not authenticate, install tools, contact cloud APIs, run `terraform init`, or
check registry login state.

| Scenario | Tools |
|----------|-------|
| Core deploy | `devspace`, `kubectl`, `helm`, `yq` |
| Local deploy with inferred Docker CIDR | `docker` unless `DOCKER_CIDR_PREFIX` is set |
| Local host integration on macOS | `brew`, `scutil`, `security`, `openssl`, `base64` |
| Local host integration on Linux | `resolvectl`, `ip`, `openssl`, `base64` |
| Managed or prepared GKE deploy | `gcloud`, `terraform`, `gke-gcloud-auth-plugin` |
| GKE host DNS integration | `dig` when `HOST_INTEGRATION=true` and `DNS_MODE=cloud-dns` |
| Managed GKE Config Connector operator install | `tar` plus `gsutil` or `gcloud storage` |
| Smoke tests | `go`; local smoke also needs `kind` |
| Chart tests | Helm `unittest` plugin |
| Optional GKE registry smoke | `docker` plus authenticated Artifact Registry access |

## Variables

Frequently used variables:

| Variable | Purpose |
|----------|---------|
| `CLUSTER_PROVIDER` | Setup/test selector. Supported values: `local`, `gke`. |
| `HOST_INTEGRATION` | Set `false` to skip host DNS and CA hooks. |
| `DNS_DOMAIN` | App route suffix, default `int.kube` locally and `GKE_DNS_DOMAIN` on GKE. |
| `DNS_MODE` | Persisted selection output: `local` or `cloud-dns`. |
| `DNS_SERVICE_ID` | Host DNS service ID for resolver configuration. |
| `GATEWAY_PROVIDER` | Route implementation selector: `local-istio` or `gke-gateway`. |
| `GKE_PROJECT_ID` | Selected GKE project. |
| `GKE_REGION` | Selected GKE region. |
| `GKE_GCLOUD_CONFIGURATION` | gcloud configuration used by GKE `ensure-cluster`; default `devspace-starter-pack`. |
| `GKE_GCLOUD_ACCOUNT` | Optional gcloud account for GKE auth bootstrap. |
| `GCP_BILLING_ACCOUNT_ID` | Managed GKE billing account; derived when exactly one open account is visible. |
| `GCP_ORG_ID` | Managed GKE organization parent; derived when exactly one org is visible and no folder is set. |
| `GCP_FOLDER_ID` | Optional managed GKE folder parent; takes precedence over `GCP_ORG_ID`. |
| `GKE_DNS_DOMAIN` | GKE DNS suffix, default `gcp.kube`. |
| `GKE_DNS_NAMESERVERS` | Cloud DNS authoritative nameservers. |
| `GKE_SELECTED_CONTEXT` | Persisted selected GKE kube context; deploy fails if it differs from the active context. |
| `GKE_PROTECTION` | GKE protected-route mode. Default `iap`; `vpn` is future work. |
| `GKE_SERVICE_EXTENSIONS_FORWARD_ATTRIBUTES` | Published `true` when the installed `GCPTrafficExtension` CRD supports `forwardAttributes`. |
| `CONFIG_CONNECTOR_ENABLED` | Opt-in Config Connector switch; default `false`, published `true` only when enabled. |
| `CONFIG_CONNECTOR_SERVICE_ACCOUNT` | Config Connector cluster-mode Google service account for managed GKE. |
| `DEV_REGISTRY` | GKE Artifact Registry Docker repository path. |
| `DEV_REGISTRY_IMAGE_PREFIX` | Image prefix consumed by app repos. |

## Cluster Environment Contract

Starter-pack publishes non-secret topology values into the active cluster:

```bash
kubectl get configmap -n devspace-system devspace-starter-pack-env -o yaml
devspace run print-cluster-env
```

Downstream repos can read the contract without invoking starter-pack through `-p with-infra`:

```bash
kubectl get configmap -n devspace-system devspace-starter-pack-env \
  -o jsonpath='{.data.DEPLOYMENT_DOMAIN}'
```

The v1 contract is owned by starter-pack and uses ConfigMap keys such as `CLUSTER_PROVIDER`,
`DEPLOYMENT_DOMAIN`, `DNS_DOMAIN`, `DNS_MODE`, `DNS_SERVICE_ID`, `GATEWAY_NAMESPACE`,
`GATEWAY_PROVIDER`, `DEV_REGISTRY_IMAGE_PREFIX`, `GKE_PROJECT_ID`, `GKE_REGION`, `GKE_PROTECTION`,
`GKE_SERVICE_EXTENSIONS_FORWARD_ATTRIBUTES`, `CONFIG_CONNECTOR_ENABLED`, `CONFIG_CONNECTOR_MODE`,
`CONFIG_CONNECTOR_PROJECT_ID`, and `CONFIG_CONNECTOR_SERVICE_ACCOUNT`. It contains topology only,
never credentials, OAuth secrets,
service account keys, or image pull secrets. Missing or incomplete GKE contract data is actionable:
run `devspace --var CLUSTER_PROVIDER=gke run ensure-cluster` from starter-pack.

## Smoke Tests

Local smoke:

```bash
make smoke
make test-e2e
```

Useful local overrides:

```bash
E2E_CLUSTER_NAME=my-smoke E2E_KEEP_CLUSTER=1 make smoke
E2E_DEVSPACE_ARGS="--profile o11y-grafana" make smoke
E2E_TIMEOUT=30m E2E_READY_TIMEOUT=10m make smoke
```

GKE smoke:

```bash
make smoke-gke
```

Timeout knobs use Go duration syntax and include `E2E_TIMEOUT`, `E2E_CLUSTER_CREATE_WAIT`,
`E2E_CLEANUP_TIMEOUT`, `E2E_READY_TIMEOUT`, `E2E_READY_REPORT_INTERVAL`,
`E2E_DIAGNOSTIC_TIMEOUT`, and `E2E_TEST_TIMEOUT`.
