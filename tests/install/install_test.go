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

	t.Run("gateway ext-authz hook", func(t *testing.T) {
		assertIstioGatewayExtAuthzHookInstalled(t)
	})

	t.Run("optional https route", func(t *testing.T) {
		assertOptionalHTTPSRoute(t)
	})

	t.Run("optional tracing stack", func(t *testing.T) {
		if !helmReleaseInstalled(t, "observability", "otel-collector") && !helmReleaseInstalled(t, "observability", "jaeger") {
			t.Skip("with-o11y profile is not installed")
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
			"metrics":   8888,
		})
		assertServiceExposesPorts(t, "observability", "jaeger", map[string]int{
			"otlp-grpc":  4317,
			"otlp-http":  4318,
			"http-query": 16686,
		})
		assertServiceMonitorInstalled(t, "observability", "otel-collector")
		assertServiceMonitorInstalled(t, "observability", "istiod")
		assertPodMonitorInstalled(t, "observability", "istio-gateway-api-gateway")
		assertPodMonitorInstalled(t, "observability", "istio-ingress-gateway")
		assertPrometheusRemoteWriteReceiverEnabled(t, "observability", "prometheus-kube-prometheus-prometheus")
		assertOptionalTracingRoute(t)
	})

	t.Run("optional grafana", func(t *testing.T) {
		if !helmReleaseInstalled(t, "observability", "grafana") {
			t.Skip("o11y-grafana profile is not installed")
		}

		assertServiceExposesPorts(t, "observability", "grafana", map[string]int{
			"service": 3000,
		})
		assertConfigMapInstalled(t, "observability", "grafana-datasource-prometheus")
		assertConfigMapInstalled(t, "observability", "grafana-dashboards-kubernetes")
		assertConfigMapInstalled(t, "observability", "grafana-dashboards-candidates")
		assertConfigMapInstalled(t, "observability", "grafana-dashboards-istio")
		assertOptionalGrafanaRoute(t)
	})

	t.Run("optional observability addons", func(t *testing.T) {
		if !helmReleaseInstalled(t, "observability", "loki") &&
			!helmReleaseInstalled(t, "observability", "tempo") &&
			!helmReleaseInstalled(t, "observability", "alloy") {
			t.Skip("o11y-addons profile is not installed")
		}

		for _, release := range []string{"loki", "tempo", "alloy"} {
			if !helmReleaseInstalled(t, "observability", release) {
				t.Fatalf("observability/%s Helm release is not deployed", release)
			}
		}
		assertConfigMapInstalled(t, "observability", "grafana-datasources-addons")
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
