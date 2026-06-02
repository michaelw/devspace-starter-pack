# Troubleshooting

## DNS

Reset and reapply host DNS integration:

```bash
devspace run reset-cluster-dns
devspace run update-cluster-dns
```

Check local DNS components:

```bash
kubectl get pods -n external-dns
kubectl get pods -n coredns
```

On macOS, prefer `dns-sd` or normal application resolution over `dig`; `dig` bypasses parts of the
system resolver path that DevSpace configures.

For GKE, confirm the selected Cloud DNS nameservers are persisted:

```bash
devspace list vars | grep GKE_DNS_NAMESERVERS
```

## Certificates

Check certificate status:

```bash
kubectl get certificates --all-namespaces
kubectl describe certificate cluster-root-ca -n cert-manager
```

Re-import the root CA:

```bash
devspace run import-root-ca
```

## Network Connectivity

On macOS local clusters, check Docker network bridging:

```bash
brew services list | grep docker-mac-net-connect
sudo brew services restart chipmk/tap/docker-mac-net-connect
```

Check MetalLB status:

```bash
kubectl get pods -n metallb-system
kubectl get ipaddresspools -n metallb-system
```

## GKE Gateway

Inspect Gateway-generated forwarding rules, backend services, and URL maps:

```bash
devspace run gke-gateway-resources
```

For raw authz/plugin requests, use `https://httpbin.gcp.kube`. HTTP should redirect to HTTPS.

For protected observability routes, unauthenticated browser or curl access should be intercepted by
IAP when `GKE_PROTECTION=iap`.

If IAP says the signed-in Google user does not have access, check that the user has
`roles/iap.httpsResourceAccessor`. Managed GKE setup defaults this to the active `gcloud` account
when no explicit accessor list is provided, but existing clusters may need a fresh
`devspace --var CLUSTER_PROVIDER=gke run ensure-cluster` after changing accessors.
