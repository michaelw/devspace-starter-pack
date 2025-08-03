# Certificate Chain Helm Chart

This Helm chart creates a complete certificate chain using cert-manager for a local development environment.

## Documentation

- [Configuration Guide](CONFIGURATION.md) - Detailed configuration options and examples
- [Schema Validation](SCHEMA.md) - VS Code integration and validation setup

## Certificate Chain Structure

1. **Self-Signed Root CA** (10-year TTL)
   - Creates a self-signed root certificate authority
   - Used to sign the intermediate CA
   - Stored in secret: `cluster-root-ca-secret`

2. **Intermediate CA** (1-year TTL)
   - Signed by the root CA
   - Used to sign leaf certificates (like gateway certificates)
   - Stored in secret: `cluster-intermediate-ca-secret`

3. **Gateway Certificate** (3-month TTL)
   - Signed by the intermediate CA
   - Used for TLS termination on gateway API listeners
   - Stored in secret: `gateway-tls-secret`

## ClusterIssuers Created

- `cluster-root-ca-issuer`: Self-signed issuer for root CA
- `cluster-intermediate-ca-issuer`: CA issuer using root CA for signing

## Installation

This chart is automatically deployed by DevSpace when running the `local` profile.

To deploy manually:

```bash
helm install cert-chain ./charts/cert-chain -f ./helm-values/cert-chain.yaml -n cert-manager
```

## Namespace Behavior

Following standard Helm practices, certificates will be created in the namespace where the chart is deployed:

- If you specify `-n cert-manager` during installation, certificates are created in the `cert-manager` namespace
- If no namespace is specified, certificates are created in the `default` namespace
- The chart uses `{{ .Release.Namespace }}` to determine the target namespace dynamically

**Note**: ClusterIssuers are cluster-scoped resources and are not affected by the installation namespace.

## Configuration

The chart can be configured through the `helm-values/cert-chain.yaml` file or by overriding values in the DevSpace configuration.

Key configuration options:

- Certificate durations and renewal times
- DNS names for gateway certificates
- Organization and country information
- Secret names for storing certificates

**Values Validation**: This chart includes a JSON schema (`values.schema.json`) that validates all configuration values. See [VALIDATION.md](./VALIDATION.md) for details on validation rules and required fields.

## Testing

This chart includes comprehensive unit tests using `helm-unittest`. The tests cover:

- **Default Values**: Tests with default configuration
- **Custom Values**: Tests with custom configuration using `test-valid-values.yaml`
- **Certificate Chain**: Tests the relationships between CA certificates and issuers
- **Validation**: Tests that valid configurations work correctly

### Running Tests

```bash
# Run all tests
./test-runner.sh

# Run only unit tests
helm unittest .

# Run only lint tests
helm lint . --strict

# Test with custom values
helm lint . --strict --values test-valid-values.yaml
```

### Test Structure

```
tests/
├── default_test.yaml           # Tests with default values
├── custom_values_test.yaml     # Tests with custom values
├── certificate_chain_test.yaml # Tests certificate relationships
└── validation_test.yaml        # Tests valid configurations
```

## Certificate Renewal

cert-manager will automatically handle certificate renewal based on the `renewBefore` settings:

- Root CA: Renews 1 year before expiry
- Intermediate CA: Renews 30 days before expiry
- Gateway Certificate: Renews 1 week before expiry

## Usage with Gateway API

The gateway certificate secret (`gateway-tls-secret`) can be referenced in Gateway API Gateway resources for TLS termination:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: my-gateway
spec:
  listeners:
  - name: https
    port: 443
    protocol: HTTPS
    tls:
      mode: Terminate
      certificateRefs:
      - name: gateway-tls-secret
        namespace: cert-manager  # Use the namespace where cert-chain was deployed
```

## Troubleshooting

Check certificate status:
```bash
# Replace <namespace> with the namespace where cert-chain was deployed
kubectl get certificates -n <namespace>
kubectl describe certificate cluster-root-ca -n <namespace>
```

Check ClusterIssuer status:
```bash
kubectl get clusterissuers
kubectl describe clusterissuer cluster-root-ca-issuer
```

View certificate details:
```bash
# Replace <namespace> with the namespace where cert-chain was deployed
kubectl get secret cluster-root-ca-secret -n <namespace> -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -text -noout
```
