//go:build linux

package install_test

import (
	"crypto/x509"
	"strings"
	"testing"
)

func hostRequiredTools() []string {
	return []string{"resolvectl"}
}

func assertHostDNS(t *testing.T, name, expectedIP string) {
	t.Helper()

	assertResolvedRouteOnlyDomain(t, "kube", expectedIP)
	assertDefaultResolverResolves(t, name, expectedIP)
}

func assertRootCAImported(t *testing.T) {
	t.Helper()

	cert := rootCACertificate(t)
	pool, err := x509.SystemCertPool()
	if err != nil {
		t.Fatalf("failed to load system certificate pool: %v", err)
	}
	if _, err := cert.Verify(x509.VerifyOptions{Roots: pool}); err != nil {
		t.Fatalf("system certificate pool does not trust current cluster root CA: %v", err)
	}
}

func assertOptionalHTTPSRoute(t *testing.T) {
	t.Helper()

	if !httpbinRouteInstalled(t) {
		t.Skip("optional httpbin route is not installed")
	}
	assertHTTPSGet(t, "HTTPS route", "https://"+routeHost("httpbin")+"/get")
	if clusterProvider() == "gke" {
		assertHTTPSHeaderPreserved(t, "httpbin Authorization header", "https://"+routeHost("httpbin")+"/headers", "Authorization", "Bearer devspace-starter-pack-test")
		assertHTTPRedirectsToHTTPS(t, "httpbin HTTP route", "http://"+routeHost("httpbin")+"/get")
	}
}

func assertOptionalTracingRoute(t *testing.T) {
	t.Helper()

	if !httpRouteInstalled(t, "observability", "jaeger") {
		t.Fatal("observability/jaeger HTTPRoute is not installed")
	}
	if clusterProvider() == "gke" && gkeProtection() == "iap" {
		assertGCPBackendPolicyInstalled(t, "observability", "jaeger-iap")
		assertHTTPSRequiresIAP(t, "Jaeger HTTPS route", "https://"+routeHost("jaeger")+"/")
		assertHTTPRedirectsToHTTPS(t, "Jaeger HTTP route", "http://"+routeHost("jaeger")+"/")
		return
	}
	assertHTTPSGet(t, "Jaeger HTTPS route", "https://"+routeHost("jaeger")+"/")
}

func assertOptionalGrafanaRoute(t *testing.T) {
	t.Helper()

	if !httpRouteInstalled(t, "observability", "grafana") {
		t.Fatal("observability/grafana HTTPRoute is not installed")
	}
	if clusterProvider() == "gke" && gkeProtection() == "iap" {
		assertGCPBackendPolicyInstalled(t, "observability", "grafana-iap")
		assertHTTPSRequiresIAP(t, "Grafana HTTPS route", "https://"+routeHost("grafana")+"/login")
		assertHTTPRedirectsToHTTPS(t, "Grafana HTTP route", "http://"+routeHost("grafana")+"/login")
		return
	}
	assertHTTPSGet(t, "Grafana HTTPS route", "https://grafana.int.kube/login")
}

func assertResolvedRouteOnlyDomain(t *testing.T, domain, expectedIP string) {
	t.Helper()

	output := runCommand(t, "resolvectl", "status")
	blocks := strings.Split(output, "\nLink ")
	for _, block := range blocks {
		if !strings.Contains(block, "DNS Servers: "+expectedIP) && !strings.Contains(block, "\n           "+expectedIP) {
			continue
		}
		if strings.Contains(block, "DNS Domain: ~"+domain) || strings.Contains(block, "DNS Domain: ") && strings.Contains(block, "~"+domain) {
			return
		}
	}

	t.Fatalf("systemd-resolved does not route ~%s to DNS server %s:\n%s", domain, expectedIP, output)
}
