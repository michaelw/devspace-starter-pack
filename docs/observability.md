# Observability

The observability stack is split into a shared base and provider overlays. `with-o11y` contains the
common Prometheus, Jaeger, and OpenTelemetry Collector pieces. `local-o11y` and `gke-o11y` activate
from the kube context for provider-specific routes and metrics settings.

Local defaults include Prometheus metrics and lightweight tracing. Grafana, Loki, Tempo, and Alloy
are optional locally. GKE auto-activates the GKE overlay and Grafana because shared clusters have
more room for the full human-facing observability surface.

## Profiles

```bash
# Shared Jaeger, Prometheus, and OpenTelemetry Collector.
# The local or GKE overlay activates from the kube context.
devspace deploy --profile with-o11y

# Add Grafana locally. GKE activates this profile automatically.
devspace deploy --profile o11y-grafana

# Add Loki, Alloy, and Tempo
devspace deploy --profile o11y-grafana,o11y-addons

# GKE explicit equivalent, normally selected automatically by context
devspace deploy --profile with-o11y,gke-o11y,o11y-grafana
```

## Routes

- Local Jaeger: `https://jaeger.int.kube`
- Local Grafana: `https://grafana.int.kube`
- GKE Jaeger: `https://jaeger.gcp.kube`
- GKE Grafana: `https://grafana.gcp.kube`

Grafana local credentials are `admin` / `admin`, as configured in `helm-values/grafana.yaml`.

On GKE, Jaeger and Grafana are protected by `GKE_PROTECTION=iap` by default. `httpbin.gcp.kube`
remains raw and non-IAP for authz/plugin testing.

## Service Export Configuration

Service repositories can export traces and metrics to the in-cluster collector:

```bash
OTEL_SERVICE_NAME=<service-name>
OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector.observability.svc.cluster.local:4317
OTEL_EXPORTER_OTLP_PROTOCOL=grpc
```

For OTLP/HTTP exporters:

```bash
OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector.observability.svc.cluster.local:4318
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
```

For host-side trace smoke tests, forward OTLP/gRPC and OTLP/HTTP:

```bash
devspace run port-forward-otel
```

## Metrics And Dashboards

Grafana reads metrics from Prometheus, including OTLP metrics remote-written by the collector. The
collector preserves resource attributes as metric labels while using a single remote-write sender
path for the in-cluster Prometheus receiver.

Istio gateway and control-plane metrics are scraped directly by Prometheus so upstream Istio RED
dashboards keep their expected metric and label shapes. Istio proxy tracing is sent to the same
OpenTelemetry Collector and Jaeger path with local-only 100% sampling.

Grafana discovers additional dashboards and datasources from Kubernetes objects:

- dashboards: ConfigMaps or Secrets with label `grafana_dashboard: "1"`
- datasources: ConfigMaps or Secrets with label `grafana_datasource: "1"`
- dashboard folders: optional annotation `grafana_folder`

The `o11y-grafana` profile installs starter dashboards in the `Kubernetes`, `Candidates`, and
`Istio` folders.
