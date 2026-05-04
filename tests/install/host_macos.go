//go:build darwin

package install_test

import (
	"crypto/tls"
	"crypto/x509"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"
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

	pool, err := x509.SystemCertPool()
	if err != nil {
		t.Fatalf("failed to load system cert pool: %v", err)
	}

	client := &http.Client{
		Timeout: 15 * time.Second,
		Transport: &http.Transport{
			TLSClientConfig: &tls.Config{RootCAs: pool, MinVersion: tls.VersionTLS12},
		},
	}
	resp, err := client.Get("https://httpbin.int.kube/get")
	if err != nil {
		t.Fatalf("HTTPS request through gateway failed: %v", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		t.Fatalf("HTTPS route returned %s: %s", resp.Status, strings.TrimSpace(string(body)))
	}
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

func httpbinRouteInstalled(t *testing.T) bool {
	t.Helper()

	output, err := runCommandE(defaultCommandTimeout, "kubectl", "get", "httproute", "http", "-n", "httpbin", "-o", "name")
	if err != nil {
		warningf(t, "optional httpbin route check skipped: %v", err)
		return false
	}
	return strings.TrimSpace(output) == "httproute.gateway.networking.k8s.io/http" || strings.TrimSpace(output) == "httproute/http"
}
