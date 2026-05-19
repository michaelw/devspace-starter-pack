//go:build darwin

package install_test

import (
	"strings"
	"testing"
)

func hostRequiredTools() []string {
	return []string{"scutil", "security"}
}

func assertHostDNS(t *testing.T, name, expectedIP string) {
	t.Helper()

	if !cgoEnabled {
		t.Fatal("host DNS validation on macOS requires CGO_ENABLED=1 so Go uses the system resolver for Supplemental Resolver domains")
	}

	assertScutilResolver(t, "kube", expectedIP)
	assertDefaultResolverResolves(t, name, expectedIP)
}

func assertRootCAImported(t *testing.T) {
	t.Helper()

	fingerprint := rootCAFingerprint(t)
	output := runCommand(t, "security", "find-certificate", "-a", "-c", "Cluster Root CA", "-Z", "/Library/Keychains/System.keychain")
	if !strings.Contains(output, "SHA-256 hash: "+fingerprint) {
		t.Fatalf("system keychain does not contain current cluster root CA fingerprint %s", fingerprint)
	}
}

func assertOptionalHTTPSRoute(t *testing.T) {
	t.Helper()

	if !httpbinRouteInstalled(t) {
		t.Skip("optional httpbin route is not installed")
	}
	if !cgoEnabled {
		t.Fatal("HTTPS route validation on macOS requires CGO_ENABLED=1 so Go uses the system resolver for .kube names")
	}

	assertHTTPSGet(t, "HTTPS route", "https://httpbin.int.kube/get")
}

func assertOptionalTracingRoute(t *testing.T) {
	t.Helper()

	if !httpRouteInstalled(t, "observability", "jaeger") {
		t.Fatal("observability/jaeger HTTPRoute is not installed")
	}
	if !cgoEnabled {
		t.Fatal("Jaeger route validation on macOS requires CGO_ENABLED=1 so Go uses the system resolver for .kube names")
	}

	assertHTTPSGet(t, "Jaeger HTTPS route", "https://jaeger.int.kube/")
}

func assertOptionalGrafanaRoute(t *testing.T) {
	t.Helper()

	if !httpRouteInstalled(t, "observability", "grafana") {
		t.Fatal("observability/grafana HTTPRoute is not installed")
	}
	if !cgoEnabled {
		t.Fatal("Grafana route validation on macOS requires CGO_ENABLED=1 so Go uses the system resolver for .kube names")
	}

	assertHTTPSGet(t, "Grafana HTTPS route", "https://grafana.int.kube/login")
}

func assertScutilResolver(t *testing.T, domain, expectedIP string) {
	t.Helper()

	output := runCommand(t, "scutil", "--dns")
	resolvers := strings.Split(output, "\nresolver #")
	for _, resolver := range resolvers {
		if !strings.Contains(resolver, "domain   : "+domain) {
			continue
		}
		for _, line := range strings.Split(resolver, "\n") {
			line = strings.TrimSpace(line)
			if strings.HasPrefix(line, "nameserver[") {
				parts := strings.SplitN(line, ":", 2)
				if len(parts) == 2 {
					got := strings.TrimSpace(parts[1])
					if got == expectedIP {
						return
					}
					t.Fatal(resolverMismatch(domain, got, expectedIP))
				}
			}
		}
		t.Fatalf("macOS resolver for %q did not list a nameserver", domain)
	}

	t.Fatalf("macOS scutil --dns does not contain a supplemental resolver for %q", domain)
}
