# Certificate Chain Helm Chart - Configuration Guide

## Overview
This Helm chart creates a complete certificate chain for cert-manager with configurable components:
- **Root CA**: Self-signed certificate authority (disabled by default)
- **Intermediate CA**: Signed by Root CA (disabled by default)
- **Gateway Certificate**: Signed by Intermediate CA (enabled by default)

## Key Features

### 1. Conditional Component Creation
- **Root CA**: `rootCA.enabled: false` (default)
- **Intermediate CA**: `intermediateCA.enabled: false` (default)
- **Gateway Certificate**: `gatewayCert.enabled: true` (default)

### 2. Configurable Issuer Types
Each component can be configured to use either:
- **Issuer**: Namespace-scoped, can only issue certificates in the same namespace
- **ClusterIssuer**: Cluster-scoped, can issue certificates across all namespaces

Default: `issuerType: "Issuer"`

### 3. Safe Optional Key Handling
Templates use safe checks for optional keys to prevent errors when keys are missing:
```yaml
{{- if (.Values.rootCA).enabled }}
```

## Configuration Examples

### Default Configuration (Gateway cert only)
```yaml
# Only gateway certificate is created
# Uses Issuer type by default
gatewayCert:
  enabled: true
  issuerType: "Issuer"
```

### Enable Full Certificate Chain with Issuers
```yaml
rootCA:
  enabled: true
  issuerType: "Issuer"

intermediateCA:
  enabled: true
  issuerType: "Issuer"

gatewayCert:
  enabled: true
  issuerType: "Issuer"
```

### Enable Full Certificate Chain with ClusterIssuers
```yaml
rootCA:
  enabled: true
  issuerType: "ClusterIssuer"

intermediateCA:
  enabled: true
  issuerType: "ClusterIssuer"

gatewayCert:
  enabled: true
  issuerType: "ClusterIssuer"
```

## Certificate Chain Flow

1. **Self-signed Issuer** → signs → **Root CA Certificate**
2. **Root CA Issuer** (using Root CA secret) → signs → **Intermediate CA Certificate**
3. **Intermediate CA Issuer** (using Intermediate CA secret) → signs → **Gateway Certificate**

## Namespace Behavior

- **Issuer**: Creates issuers with `namespace: {{ .Release.Namespace }}`
- **ClusterIssuer**: Creates cluster-wide issuers without namespace restrictions
- **Certificates**: Always created in `{{ .Release.Namespace }}`

## Testing

Run unit tests to verify functionality:
```bash
helm unittest cert-chain
```

## Deployment Examples

### Install with only gateway certificate (default):
```bash
helm install my-certs ./cert-chain
```

### Install with full CA chain using Issuers:
```bash
helm install my-certs ./cert-chain \
  --set rootCA.enabled=true \
  --set intermediateCA.enabled=true
```

### Install with full CA chain using ClusterIssuers:
```bash
helm install my-certs ./cert-chain \
  --set rootCA.enabled=true \
  --set intermediateCA.enabled=true \
  --set rootCA.issuerType=ClusterIssuer \
  --set intermediateCA.issuerType=ClusterIssuer \
  --set gatewayCert.issuerType=ClusterIssuer
```
