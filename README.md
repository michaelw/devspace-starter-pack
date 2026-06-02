# DevSpace Starter Pack

A local Kubernetes development environment on macOS using [DevSpace](https://devspace.sh),
featuring Gateway, observability, DNS integration, and certificate management.

## TL;DR

```bash
devspace deploy
```

[![asciicast](https://asciinema.org/a/xQCFZrnnhBgVisgZg8HFtAviH.svg)](https://asciinema.org/a/xQCFZrnnhBgVisgZg8HFtAviH)

## Purpose

This starter pack provides a complete local Kubernetes development infrastructure with:

- **HTTP(S) Gateway**: Istio with Gateway API and Ingress for traffic management
- **Load Balancing**: MetalLB for LoadBalancer services on local clusters
- **DNS Integration**: External DNS with CoreDNS for `.kube` domain resolution
- **Certificate Management**: Complete CA chain with cert-manager and trust-manager
- **Observability**: Local OpenTelemetry tracing plus optional metrics/logs add-ons
- **Data Storage**: PostgreSQL, Redis, and ElasticSearch options
- **Developer Experience**: Automatic certificate import, DNS configuration, and network setup

## Prerequisites

Install these tools before using the local path:

- **DevSpace** >= v6.0
- **kubectl**
- **Helm** >= v3
- **yq** >= v4

Supported local Kubernetes contexts are Docker Desktop, Minikube, Rancher Desktop, MicroK8s, and
`kind*`. macOS host integration also requires Homebrew and admin privileges for DNS and certificate
trust setup.

GKE setup additionally requires `terraform`, `gcloud`, and `gke-gcloud-auth-plugin`. Config
Connector is opt-in and additionally needs `tar` plus `gsutil` or `gcloud storage` to install the
operator bundle. GKE `ensure-cluster` bootstraps Google login, derives unambiguous billing/org
inputs from the logged-in account, and tells you which `devspace set var ...` command to run when it
cannot choose. Run `devspace run check-tools` for a fast local preflight; it checks tools only and
does not authenticate or install anything. See [GKE setup](docs/gke.md).

## Getting Started

```bash
git clone <repository-url>
cd devspace-starter-pack

devspace deploy
```

DevSpace auto-selects local or GKE profiles from the active kube context. Select the local workflow
explicitly when you want to persist the current local context and DNS defaults:

```bash
devspace run ensure-cluster
```

Verify the install:

```bash
devspace run test-install
kubectl get pods --all-namespaces
devspace run print-cluster-env
```

On macOS, use system resolver tools for DNS checks:

```bash
dns-sd -q ns.dns.kube
```

`dig` does not exercise the same macOS resolver path.

## Common Workflows

Add common optional services:

```bash
# Databases
devspace deploy --profile local-psql,local-redis

# Grafana
devspace deploy --profile o11y-grafana

# Grafana, logs, and Tempo
devspace deploy --profile o11y-grafana,o11y-addons
```

Manage host DNS and trust integration:

```bash
devspace run update-cluster-dns
devspace run reset-cluster-dns
devspace run import-root-ca
```

Use GKE instead of a local cluster:

```bash
devspace --var CLUSTER_PROVIDER=gke run ensure-cluster

devspace deploy --var HOST_INTEGRATION=false
```

If your account can see multiple billing accounts or organizations, `ensure-cluster` stops before
Terraform and prints the exact `devspace set var ...` command to disambiguate.

Select an already-prepared GKE cluster by switching to its `gke_*` kube context, setting the
non-derivable deploy inputs, and running the same command:

```bash
kubectl config use-context gke_PROJECT_REGION_CLUSTER
devspace set var GKE_DNS_NAMESERVERS=ns-cloud-example1.googledomains.com.,ns-cloud-example2.googledomains.com.
devspace run ensure-cluster
```

Full GKE setup, DNS, IAP, Config Connector, registry, and smoke details are in
[docs/gke.md](docs/gke.md).

## Validation

Run the advertised local deploy path against a throwaway cluster:

```bash
make smoke
```

Run the GKE smoke path:

```bash
make smoke-gke
```

Run only the install diagnostics for the current context:

```bash
devspace run test-install
```

More test knobs and smoke harness details are in
[docs/devspace-reference.md](docs/devspace-reference.md).

## Profiles And Commands

DevSpace auto-activates the base local or GKE infrastructure profiles from the kube context. Add
optional profiles only for workloads you want on top:

| Need | Profiles |
|------|----------|
| Local databases | `local-psql`, `local-redis`, `local-es` |
| Metrics, tracing, Jaeger | `with-o11y` plus context-activated `local-o11y` or `gke-o11y` |
| Grafana | `o11y-grafana` (`GKE` auto-activates it; local clusters opt in) |
| Logs and Tempo | `o11y-addons` |

Useful commands:

```bash
devspace list commands
devspace run ensure-cluster
devspace --var CLUSTER_PROVIDER=gke run ensure-cluster
devspace run print-cluster-env
devspace run check-gke-service-extensions
devspace run gke-gateway-resources
devspace run gke-dev-registry-info
devspace run port-forward-otel
```

Starter-pack publishes a non-secret cluster environment contract at
`devspace-system/devspace-starter-pack-env`. App repos can read provider, domain, gateway, and
registry settings directly from the active cluster without a local starter-pack checkout.

The full profile, command, variable, and smoke-reference tables live in
[docs/devspace-reference.md](docs/devspace-reference.md).

## Feature Guides

- [GKE setup and validation](docs/gke.md)
- [Gateway and authz attachment conventions](docs/gateway-authz.md)
- [Observability](docs/observability.md)
- [DevSpace reference](docs/devspace-reference.md)
- [Troubleshooting](docs/troubleshooting.md)

Customize Helm values in `helm-values/`. Customize the certificate chain in
`charts/cert-chain/values.yaml`.

## Cleanup

Remove all deployed resources:

```bash
devspace purge
```

Reset macOS DNS configuration:

```bash
devspace run reset-cluster-dns
```

For GKE Terraform cleanup, see [docs/gke.md](docs/gke.md).

## License

Licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE) for the full license text.
