package install_test

import (
	"strings"
	"testing"
)

const (
	dnsNamespace = "external-dns"
	dnsService   = "coredns-external"
	dnsName      = "ns.dns.kube"
	rootCASecret = "cluster-root-ca-secret"
)

var checkedNamespaces = []string{
	"cert-manager",
	"external-dns",
	"istio-ingress",
	"istio-system",
	"kube-system",
	"metallb-system",
	"observability",
	"reflector",
	"reloader",
}

func TestDevspaceInstallDiagnostics(t *testing.T) {
	t.Run("tooling", func(t *testing.T) {
		requireTools(t, requiredTools()...)
		requireKubernetesContext(t)
	})

	t.Run("helm releases", func(t *testing.T) {
		assertHelmReleasesDeployed(t)
	})

	t.Run("workload readiness", func(t *testing.T) {
		assertWorkloadsReady(t, checkedNamespaces)
		assertPodsReady(t, checkedNamespaces)
	})

	t.Run("service endpoints", func(t *testing.T) {
		assertServicesHaveReadyEndpoints(t, checkedNamespaces)
	})

	t.Run("load balancers", func(t *testing.T) {
		assertLoadBalancersAssigned(t, checkedNamespaces)
	})

	t.Run("external dns path", func(t *testing.T) {
		dnsIP := requireServiceLoadBalancerIP(t, dnsNamespace, dnsService)
		assertDirectDNSResolves(t, dnsIP, dnsName, dnsIP)
	})

	t.Run("host dns", func(t *testing.T) {
		dnsIP := requireServiceLoadBalancerIP(t, dnsNamespace, dnsService)
		assertHostDNS(t, dnsName, dnsIP)
	})

	t.Run("certificates", func(t *testing.T) {
		assertCertManagerResourcesReady(t)
		assertRootCAImported(t)
	})

	t.Run("optional https route", func(t *testing.T) {
		assertOptionalHTTPSRoute(t)
	})

	t.Run("optional tracing stack", func(t *testing.T) {
		if !helmReleaseInstalled(t, "observability", "otel-collector") && !helmReleaseInstalled(t, "observability", "jaeger") {
			t.Skip("optional with-o11y profile is not installed")
		}
		if !helmReleaseInstalled(t, "observability", "otel-collector") {
			t.Fatal("observability/otel-collector Helm release is not deployed")
		}
		if !helmReleaseInstalled(t, "observability", "jaeger") {
			t.Fatal("observability/jaeger Helm release is not deployed")
		}

		assertServiceExposesPorts(t, "observability", "otel-collector", map[string]int{
			"otlp":      4317,
			"otlp-http": 4318,
		})
		assertServiceExposesPorts(t, "observability", "jaeger", map[string]int{
			"otlp-grpc":  4317,
			"otlp-http":  4318,
			"http-query": 16686,
		})
		assertOptionalTracingRoute(t)
	})
}

func requiredTools() []string {
	tools := []string{"kubectl", "helm"}
	tools = append(tools, hostRequiredTools()...)
	return tools
}

func hasAnyPrefix(value string, prefixes ...string) bool {
	for _, prefix := range prefixes {
		if strings.HasPrefix(value, prefix) {
			return true
		}
	}
	return false
}
