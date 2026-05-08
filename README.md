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

### Required Tools

- **DevSpace** (>= v6.0): [Install Guide](https://devspace.sh/docs/getting-started/installation)
- **kubectl**: Kubernetes CLI
- **yq** (>= v4): YAML processor
- **Helm** (>= v3): Package manager for Kubernetes

### Supported Kubernetes Platforms

- Docker Desktop
- Minikube (edit `DOCKER_CIDR_PREFIX`)

### macOS-Specific Requirements

- **Homebrew**: For installing `docker-mac-net-connect`
- **Admin privileges**: Required for DNS configuration and certificate import

## Getting Started

### 1. Clone and Navigate

```bash
git clone <repository-url>
cd devspace-starter-pack
```

### 2. Deploy Infrastructure

Deploy all infrastructure components:

```bash
devspace deploy
```

Deploy specific profiles:

```bash
# Add databases
devspace deploy --profile local-psql,local-redis

# Add Grafana
devspace deploy --profile o11y-grafana

# Add logs and Grafana trace backend addons
devspace deploy --profile o11y-grafana,o11y-addons
```

### 3. Verify Installation

Check that all components are running:

```bash
kubectl get pods --all-namespaces
```

Test DNS resolution:

```bash
dns-sd -q ns.dns.kube
```

**NOTE**: on macOS, do not rely on `dig` for testing DNS resolution.

## Available Profiles

| Profile | Description | Components |
|---------|-------------|------------|
| `local-network` | Core networking infrastructure | MetalLB, Istio, Gateway API |
| `local-dns` | DNS integration for development | External DNS, CoreDNS, etcd |
| `local-certs` | Certificate management | cert-manager, trust-manager, reflector |
| `local-aux` | Auxiliary services | Reloader |
| `local-test` | Test applications | httpbin with routes |
| `with-o11y` | Core observability | Prometheus, metrics-server, OpenTelemetry Collector, Jaeger |
| `o11y-grafana` | Grafana UI | Grafana, Grafana HTTPRoute, datasource/dashboard sidecars |
| `o11y-addons` | Extended observability | Alloy, Loki, Tempo, Grafana datasource ConfigMaps |
| `local-psql` | PostgreSQL database | PostgreSQL with persistence |
| `local-redis` | Redis cache | Redis with persistence |
| `local-es` | ElasticSearch | Single-node ElasticSearch |

## Available Commands

Find all available commands:

```bash
devspace list commands
```

### Network Commands

```bash
# Configure host DNS to use cluster DNS for .kube domains
devspace run update-cluster-dns

# Reset DNS configuration
devspace run reset-cluster-dns

# Import cluster root CA certificate to macOS keychain
devspace run import-root-ca
```

### Observability Commands

The tracing services are `ClusterIP` services by default. Service workloads should use the in-cluster
collector DNS name directly. The Jaeger UI is exposed through the shared local HTTPS gateway at
`https://jaeger.int.kube`. Grafana is available at `https://grafana.int.kube` when the
`o11y-grafana` profile is deployed.

```bash
# Forward OTLP/gRPC and OTLP/HTTP for host-side trace smoke tests
devspace run port-forward-otel
```

## Key Features

### Automatic macOS Integration

- **Network Connectivity**: Automatically installs and configures `docker-mac-net-connect` for seamless networking
- **DNS Integration**: Configures macOS to resolve `.kube` domains through the cluster DNS
- **Certificate Trust**: Imports cluster CA certificates to macOS keychain for trusted HTTPS

### HTTP(S) Gateway with Istio

- `*.int.kube` autowired for Gateway API
- `*.istio.kube` autowired for Istio Ingress
- Gateway API and Istio Ingress support for traffic management
- Automatic TLS termination with custom certificates
- Traffic routing for microservices

### Certificate Management

- Complete CA chain (Cluster Root CA → Intermediate CA → Leaf certificates)
- Automatic certificate renewal
- Trust bundle distribution across namespaces
- Custom certificate chain in `charts/cert-chain/`

### Local DNS Resolution

- `.kube` domain resolution for all services of type `Loadbalancer`
- External DNS automatically creates DNS records

### Observability Stack

- **OpenTelemetry Collector**: Local OTLP/gRPC and OTLP/HTTP trace receiver for service repositories
- **Jaeger**: Lightweight trace UI with transient in-memory storage
- **Prometheus**: Default local metrics collection and alerting
- **Grafana**: Optional visualization with default local cluster dashboards and dashboard provisioning
- **Loki**: Optional log aggregation
- **Tempo**: Optional distributed tracing backend
- **Alloy**: Optional OpenTelemetry collection

The default local deployment includes Prometheus and lightweight tracing. Deploy Grafana when a
host-browser UI is needed:

```bash
devspace deploy --profile o11y-grafana
```

Service repositories can export traces and metrics to the collector with:

```bash
OTEL_SERVICE_NAME=<service-name>
OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector.observability.svc.cluster.local:4317
OTEL_EXPORTER_OTLP_PROTOCOL=grpc
```

For OTLP/HTTP exporters, use:

```bash
OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector.observability.svc.cluster.local:4318
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
```

Open the trace UI at `https://jaeger.int.kube`. In-cluster workloads export to
`otel-collector.observability.svc.cluster.local` without port-forwarding. Grafana reads metrics from
Prometheus, including OTLP metrics remote-written by the collector. The collector preserves resource
attributes as metric labels for local querying, while keeping a single remote-write sender path for
the in-cluster Prometheus receiver.

Istio gateway and control-plane metrics are scraped directly by Prometheus so the official Istio RED
dashboards keep their upstream metric and label expectations. Istio proxy tracing is sent to the same
OpenTelemetry Collector and Jaeger path with local-only 100% sampling.

Open Grafana at `https://grafana.int.kube` and log in with `admin` / `admin`
(the local-only credentials configured in `helm-values/grafana.yaml`).

Deploy Loki, Alloy, and Tempo when logs or Grafana-backed trace exploration are needed:

```bash
devspace deploy --profile o11y-grafana,o11y-addons
```

Grafana discovers additional dashboards and datasources from Kubernetes objects:

- Dashboards: create a ConfigMap or Secret with label `grafana_dashboard: "1"` and dashboard JSON data.
- Datasources: create a ConfigMap or Secret with label `grafana_datasource: "1"` and Grafana provisioning YAML.
- Optional dashboard folders: set annotation `grafana_folder` on the dashboard ConfigMap or Secret.
- These objects can live in service repository namespaces; the Grafana sidecars watch all namespaces.

The `o11y-grafana` profile installs starter dashboards in the `Kubernetes` folder for API server,
compute resource, and kubelet/runtime health.

It also installs upstream Grafana.com dashboards in the `Candidates` folder for comparison:
`Kubernetes Overview` and `OpenTelemetry Collector`. `Kubernetes Overview` is configured as the
Grafana home dashboard for the local instance.

The `Istio` folder contains official Istio `1.26.2` dashboards for mesh, service, workload, and
control-plane RED drilldowns.

### Helm Values

Customize component configurations in `helm-values/`:

### Certificate Configuration

Customize the certificate chain in `charts/cert-chain/values.yaml` or create custom values files.

## Troubleshooting

### DNS Issues

```bash
# Check DNS configuration
devspace run reset-cluster-dns
devspace run update-cluster-dns

# Verify CoreDNS is running
kubectl get pods -n external-dns
```

### Certificate Issues

```bash
# Check certificate status
kubectl get certificates --all-namespaces
kubectl describe certificate cluster-root-ca -n cert-manager

# Re-import root CA
devspace run import-root-ca
```

### Network Connectivity

```bash
# Check docker-mac-net-connect status
brew services list | grep docker-mac-net-connect

# Restart network connectivity
sudo brew services restart chipmk/tap/docker-mac-net-connect
```

### LoadBalancer Issues

```bash
# Check MetalLB status
kubectl get pods -n metallb-system
kubectl get ipaddresspools -n metallb-system
```

## Development Workflow

1. **Deploy Infrastructure**: `devspace deploy --profile local-network,local-certs`
2. **Add DNS** (optional): `devspace deploy --profile local-dns`
3. **Use Metrics/Tracing**: included by default through `with-o11y` on local clusters
4. **Add Grafana** (optional): `devspace deploy --profile o11y-grafana`
5. **Add Logs/Tempo** (optional): `devspace deploy --profile o11y-grafana,o11y-addons`
6. **Deploy Your Applications**: Use the configured Gateway and DNS
7. **Access Services**: Via `*.kube` domains with automatic HTTPS

## Cleanup

Remove all deployed resources:

```bash
devspace purge
```

Reset macOS DNS configuration:

```bash
devspace run reset-cluster-dns
```

## License

Licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE) for the full license text.
