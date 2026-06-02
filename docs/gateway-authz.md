# Gateway And Authz Attachment

Starter-pack provides route and gateway surfaces, but plugin or application repos own their authz
backend, policy attachment, tests, and cleanup.

## Local Istio Gateway

Local clusters expose:

- `*.int.kube` through Gateway API
- `*.istio.kube` through Istio Ingress
- HTTPS termination with starter-pack certificates

The Istio mesh config defines an optional Gateway API external authorization provider named
`gateway-ext-authz-grpc`. It is inert until an app installs an AuthorizationPolicy that uses it.
Starter-pack does not install an ext-authz backend, create a `gateway-ext-authz` Service, or create a
default reject-all AuthorizationPolicy.

Apps that want gateway-level external authorization should install:

- an ext-authz backend
- a Service alias named `gateway-ext-authz` in namespace `istio-ingress`
- port `3001`, using Envoy `ext_authz` gRPC
- an AuthorizationPolicy targeting the Gateway-generated gateway workload label
  `gateway.networking.k8s.io/gateway-name=gateway`

Example AuthorizationPolicy:

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: example-gateway-ext-authz
  namespace: istio-ingress
spec:
  selector:
    matchLabels:
      gateway.networking.k8s.io/gateway-name: gateway
  action: CUSTOM
  provider:
    name: gateway-ext-authz-grpc
  rules:
    - {}
```

Example Service alias:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: gateway-ext-authz
  namespace: istio-ingress
spec:
  type: ExternalName
  externalName: my-ext-authz.my-app-namespace.svc.cluster.local
  ports:
    - name: grpc
      port: 3001
      targetPort: 3001
```

## GKE Gateway

The GKE target exposes `*.gcp.kube` through a regional external managed GKE Gateway and Cloud DNS.
It prepares the project for Google Cloud Service Extensions and Network Security authorization
policies, but it does not attach an authorization callout by default.

GKE Service Extensions are Preview, and the `GCPTrafficExtension` schema is owned by Google's
managed Gateway API CRD bundle. Plugin repos that use `GCPTrafficExtension` attribute forwarding
should require:

```bash
devspace run check-gke-service-extensions
```

or read `GKE_SERVICE_EXTENSIONS_FORWARD_ATTRIBUTES=true` from
`devspace-system/devspace-starter-pack-env`. The required CRD field is
`spec.extensionChains[].extensions[].forwardAttributes`, used with explicit `forwardHeaders` to
forward request attributes such as `request.method`, `request.scheme`, `request.host`,
`request.path`, and `request.query` to ext_proc callouts.

The stable GKE authz backend convention mirrors the local attachment surface:

- backend namespace: owned by the plugin repo
- backend Service name: `gateway-ext-authz`
- backend Service port: `3001`
- protocol: Envoy `ext_authz` gRPC, imported as `wireFormat: EXT_AUTHZ_GRPC`
- health expectation: the Service has ready endpoints before a plugin imports an authorization
  extension pointing at it
- default attachment state: no `AuthzExtension` and no Network Security authz policy

`httpbin.gcp.kube` is the raw authz/plugin development surface and is intentionally not IAP-protected.

Plugin repos should discover the active provider, deployment domain, Gateway namespace, and GKE
registry prefix from the starter-pack-owned ConfigMap when it exists:

```bash
kubectl get configmap -n devspace-system devspace-starter-pack-env \
  -o jsonpath='{.data.DEPLOYMENT_DOMAIN}'
```

On GKE, a missing contract should be treated as an actionable setup failure: run
`devspace --var CLUSTER_PROVIDER=gke run ensure-cluster` from starter-pack.

Plugin repos that want GKE gateway-level authorization should deploy their backend and own the
concrete GKE authz manifests that attach it to the Gateway path. That usually means creating a
`GCPAuthzExtension` or traffic extension plus the scoped policy/attachment for a chosen host such as
`httpbin.gcp.kube`, depending on the extension API version installed in the target cluster.

Discover Gateway-generated load balancer resources:

```bash
devspace run gke-gateway-resources
```

Starter-pack intentionally does not ship reusable GKE authz templates; plugin repos own the exact
resources because policy shape and forwarded attributes are plugin-specific.
