# GKE Setup And Validation

The GKE target creates or selects a development cluster that uses GKE Gateway API, Cloud DNS,
Artifact Registry, Workload Identity, and the starter-pack certificate chain. It does not deploy
Istio, MetalLB, CoreDNS, or etcd.

## Prerequisites

- `terraform`
- `gcloud`
- `gke-gcloud-auth-plugin`
- Google user account with permission to create projects, link billing, and create IAM/service resources
- Access to one open billing account
- Access to one GCP organization, or an explicit folder ID

`ensure-cluster` validates and bootstraps Google auth before Terraform runs. It uses a gcloud
configuration named `devspace-starter-pack` by default, validates both gcloud CLI credentials and
Application Default Credentials, and runs an interactive browser login when either credential store
is missing or expired.

Manual fallback:

```bash
gcloud config configurations activate devspace-starter-pack
gcloud config set account ACCOUNT
gcloud auth login ACCOUNT --update-adc
```

Terraform uses Application Default Credentials. `gcloud` commands and the GKE kubectl auth plugin
use gcloud CLI credentials, so both stores must be valid. Override the config or account with
`GKE_GCLOUD_CONFIGURATION` and `GKE_GCLOUD_ACCOUNT` when needed.

After login, `ensure-cluster` derives `GCP_BILLING_ACCOUNT_ID` from the single visible open billing
account and `GCP_ORG_ID` from the single visible organization when those values are unambiguous. If
there are none or several, it stops before Terraform and prints the exact `devspace set var ...`
command to run. `GCP_FOLDER_ID` is never guessed; set it explicitly when the project should live in
a folder.

## Managed GKE Cluster

The managed path converges the Terraform in `infra/gcp-ephemeral`, selects the resulting GKE kube
context, and persists the DevSpace variables that normal deploys need.

```bash
devspace --var CLUSTER_PROVIDER=gke run ensure-cluster
```

`GKE_REGION` defaults to `us-central1`; set it only when you want a different region:

```bash
devspace set var GKE_REGION=us-east1
```

Use `GCP_FOLDER_ID` when the project parent is a folder:

```bash
devspace set var GCP_FOLDER_ID=FOLDER_ID
```

If both `GCP_FOLDER_ID` and `GCP_ORG_ID` are set, Terraform uses the folder. The command also reads
existing values from `infra/gcp-ephemeral/terraform.tfvars` when present.

Terraform creates:

- a dedicated GCP project
- an Autopilot GKE cluster
- a public Cloud DNS zone for `gcp.kube.`
- Workload Identity wiring for `external-dns`
- an Artifact Registry Docker repository for development images
- IAP API and project-scope accessor IAM for protected human-facing routes
- a Config Connector controller service account and Workload Identity binding

Check the installed Service Extensions CRD capability before deploying a plugin that uses forwarded
request attributes:

```bash
devspace run check-gke-service-extensions
```

The check requires `forwardAttributes` so plugin repos can forward attributes such as
`request.method`, `request.scheme`, `request.host`, `request.path`, and `request.query` to an
ext_proc callout. If the check fails, upgrade the GKE control plane to a version whose
Google-managed Gateway API CRD bundle includes that field, then retry:

```bash
devspace run check-gke-service-extensions
```

Useful Terraform inputs:

```hcl
dev_registry_writer_members = [
  "user:developer@example.com",
  "group:platform@example.com",
  "serviceAccount:ci@example-project.iam.gserviceaccount.com",
]

iap_accessor_members = [
  "user:developer@example.com",
  "group:platform@example.com",
]
```

When `GKE_PROTECTION=iap`, `ensure-cluster` grants browser access to the active `gcloud` account if
neither `GKE_IAP_ACCESSOR_MEMBERS` nor `iap_accessor_members` is set. Set either value explicitly to
grant a different user, group, or service account.

## Prepared Or External GKE Cluster

Use the same `ensure-cluster` command when Terraform has already prepared the project, registry, DNS
zone, and Gateway-compatible cluster, or when you are selecting an external compatible GKE cluster.
Switch to the target `gke_*` kube context first. If the context matches the Terraform outputs,
DevSpace reconverges Terraform and refreshes outputs. If it does not match, DevSpace treats the
cluster as external and does not run Terraform.

```bash
kubectl config use-context gke_PROJECT_REGION_CLUSTER
devspace set var GKE_DNS_NAMESERVERS=ns-cloud-example1.googledomains.com.,ns-cloud-example2.googledomains.com.
devspace run ensure-cluster
```

`ensure-cluster` persists `GKE_SELECTED_CONTEXT` with the selected kube context. Later
`devspace deploy`, `devspace build`, and `devspace run` commands reuse the selected GKE context,
registry, DNS, and gateway settings. If the current GKE context differs from
`GKE_SELECTED_CONTEXT`, deploy fails early and asks you to rerun
`devspace --var CLUSTER_PROVIDER=gke run ensure-cluster`.

`ensure-cluster` also publishes the non-secret cluster environment contract in
`devspace-system/devspace-starter-pack-env`. Plugin repos can discover `DEPLOYMENT_DOMAIN`,
`GKE_PROJECT_ID`, `GKE_REGION`, `GKE_PROTECTION`, `GKE_SERVICE_EXTENSIONS_FORWARD_ATTRIBUTES`,
`GATEWAY_NAMESPACE`, `GATEWAY_PROVIDER`, `DNS_DOMAIN`, and
`DEV_REGISTRY_IMAGE_PREFIX` from the cluster alone:

```bash
kubectl get configmap -n devspace-system devspace-starter-pack-env \
  -o jsonpath='{.data.DEV_REGISTRY_IMAGE_PREFIX}'
```

## Routes And Protection

GKE app routes use HTTPS backend routes plus HTTP-to-HTTPS redirects. The default protection mode is
`GKE_PROTECTION=iap` for human/shared routes such as `jaeger.gcp.kube` and `grafana.gcp.kube`.
Starter-pack applies per-Service `GCPBackendPolicy` resources; IAP is not a global Gateway switch.

By default, IAP uses Google-managed OAuth, so no OAuth client ID or secret is required:

```bash
devspace deploy
```

On a GKE kube context, DevSpace activates `with-o11y`, `gke-o11y`, and `o11y-grafana`
automatically. `with-o11y` provides the common Prometheus, Jaeger, and OpenTelemetry Collector
deployments; `gke-o11y` adds the GKE route, managed-cluster Prometheus overrides, and IAP policies.

Custom OAuth clients are only for advanced branding or external-user requirements. If used, provide
both `GKE_IAP_OAUTH_CLIENT_ID` and `GKE_IAP_OAUTH_CLIENT_SECRET`; setting only one fails during Helm
rendering. `GKE_PROTECTION=vpn` is reserved for future private Gateway access and fails clearly.

IAP browser access is IAM-controlled separately from GCP project access. Managed GKE setup defaults
the accessor list to the active `gcloud` account; add more accessors with
`GKE_IAP_ACCESSOR_MEMBERS` or `iap_accessor_members`.

`httpbin.gcp.kube` is intentionally not IAP-protected. It is the raw authz/plugin test surface, so
headers such as `Authorization: Bearer ...` reach the Gateway/authz/backend path.

## Config Connector

Config Connector is opt-in for managed GKE. Enable it before running `ensure-cluster`:

```bash
devspace set var CONFIG_CONNECTOR_ENABLED=true
devspace --var CLUSTER_PROVIDER=gke run ensure-cluster
```

When enabled, managed GKE installs the Config Connector operator from Google's official Autopilot
operator bundle during `devspace deploy`, then applies one cluster-wide `ConfigConnector` resource
using the Terraform-created Google service account. The GKE Config Connector add-on is not used
because GKE Autopilot rejects that cluster add-on.

The default IAM role set is intentionally broad for this ephemeral developer project, so downstream
repos can apply Google Cloud resources as Kubernetes manifests without adding Terraform. Override
`config_connector_iam_roles` in `infra/gcp-ephemeral/terraform.tfvars` only when you want to narrow
or expand that controller identity.

No service account keys, Kubernetes Secrets, OAuth secrets, or `imagePullSecrets` are created for
Config Connector. Authentication uses Workload Identity Federation for GKE:

```text
cnrm-system/cnrm-controller-manager -> config-connector@PROJECT_ID.iam.gserviceaccount.com
```

Downstream repos can discover whether Config Connector is available from the cluster contract. The
default value is `false`:

```bash
kubectl get configmap -n devspace-system devspace-starter-pack-env \
  -o jsonpath='{.data.CONFIG_CONNECTOR_ENABLED}'
```

Config Connector resources must still identify the target project. Use either a namespace annotation
or an annotation on each resource:

```yaml
metadata:
  annotations:
    cnrm.cloud.google.com/project-id: PROJECT_ID
```

This is not enabled automatically for external GKE clusters. External clusters can still publish
compatible metadata if their operator and IAM setup are managed separately.

## Dev Image Registry

GKE app repos should push local developer/test images to the ephemeral project's Artifact Registry
Docker repository. GHCR remains for CI-published and release artifacts.

Starter-pack exports:

- `DEV_REGISTRY_HOST`, for example `us-central1-docker.pkg.dev`
- `DEV_REGISTRY`, for example `us-central1-docker.pkg.dev/devspace-gke-example/devspace-dev`
- `DEV_REGISTRY_IMAGE_PREFIX`, normally equal to `DEV_REGISTRY`

Tag app images as:

```bash
${DEV_REGISTRY_IMAGE_PREFIX}/my-app:${TAG}
```

Do not add Kubernetes `imagePullSecrets` for this registry. GKE nodes pull with their Google service
account, which Terraform grants `roles/artifactregistry.reader` on the repository. Developer and CI
push identities must be listed in `dev_registry_writer_members`.

Authenticate Docker pushes from a developer machine:

```bash
gcloud auth configure-docker us-central1-docker.pkg.dev
```

Run the opt-in registry smoke after authenticating:

```bash
GKE_REGISTRY_SMOKE=1 CLUSTER_PROVIDER=gke go test -count=1 -v -timeout 10m ./tests/install
```

## Smoke Validation

Run the GKE smoke:

```bash
make smoke-gke
```

Useful overrides:

```bash
GKE_TF_VAR_FILE=terraform.tfvars make smoke-gke
E2E_KEEP_CLUSTER=1 GKE_TF_VAR_FILE=terraform.tfvars make smoke-gke
E2E_DEVSPACE_ARGS="--profile with-test" make smoke-gke
E2E_DEVSPACE_ARGS="--profile with-test,with-o11y,gke-o11y,o11y-grafana" make smoke-gke
```

The smoke harness exports Terraform outputs into DevSpace as `GKE_PROJECT_ID`,
`GKE_DNS_NAMESERVERS`, `DEV_REGISTRY_HOST`, `DEV_REGISTRY`, `DEV_REGISTRY_IMAGE_PREFIX`, and related
variables. On macOS, the DNS hook installs a supplemental resolver for `gcp.kube` that points at the
Cloud DNS authoritative nameservers.

## Cleanup

Purge Kubernetes resources with DevSpace:

```bash
devspace purge
devspace run reset-cluster-dns
```

Destroy managed GKE infrastructure with Terraform when the ephemeral project is no longer needed:

```bash
terraform -chdir=infra/gcp-ephemeral destroy
```
