package install_test

import (
	"crypto/tls"
	"crypto/x509"
	"errors"
	"io"
	"net"
	"net/http"
	"strings"
	"testing"
	"time"
)

func assertHTTPSGet(t *testing.T, description, url string) {
	t.Helper()

	client := trustedHTTPClient(t, true)
	deadline := time.Now().Add(45 * time.Second)
	for {
		resp, err := client.Get(url)
		if err == nil {
			defer resp.Body.Close()
			body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
			if resp.StatusCode < 200 || resp.StatusCode >= 300 {
				t.Fatalf("%s returned %s: %s", description, resp.Status, strings.TrimSpace(string(body)))
			}
			return
		}

		if time.Now().After(deadline) || !isRetryableHTTPGetError(err) {
			t.Fatalf("%s through gateway failed: %v", description, err)
		}

		time.Sleep(2 * time.Second)
	}
}

func assertHTTPSHeaderPreserved(t *testing.T, description, url, name, value string) {
	t.Helper()

	client := trustedHTTPClient(t, true)
	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		t.Fatalf("failed to build %s request: %v", description, err)
	}
	req.Header.Set(name, value)

	resp := doRequestWithRetry(t, client, req, description+" through gateway")
	defer resp.Body.Close()

	body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		t.Fatalf("%s returned %s: %s", description, resp.Status, strings.TrimSpace(string(body)))
	}
	if !strings.Contains(string(body), value) {
		t.Fatalf("%s did not preserve %s header value %q: %s", description, name, value, strings.TrimSpace(string(body)))
	}
}

func assertHTTPRedirectsToHTTPS(t *testing.T, description, url string) {
	t.Helper()

	client := trustedHTTPClient(t, false)
	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		t.Fatalf("failed to build %s redirect request: %v", description, err)
	}
	resp := doRequestWithRetry(t, client, req, description+" redirect check")
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusMovedPermanently {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		t.Fatalf("%s returned %s, expected 301 Moved Permanently: %s", description, resp.Status, strings.TrimSpace(string(body)))
	}
	location := resp.Header.Get("Location")
	if !strings.HasPrefix(location, "https://") {
		t.Fatalf("%s redirect Location is %q, expected https://...", description, location)
	}
}

func assertHTTPSRequiresIAP(t *testing.T, description, url string) {
	t.Helper()

	client := trustedHTTPClient(t, false)
	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		t.Fatalf("failed to build %s IAP request: %v", description, err)
	}
	resp := doRequestWithRetry(t, client, req, description+" IAP check")
	defer resp.Body.Close()

	if resp.StatusCode == http.StatusUnauthorized || resp.StatusCode == http.StatusForbidden {
		return
	}
	if resp.StatusCode >= 300 && resp.StatusCode < 400 {
		location := resp.Header.Get("Location")
		if strings.Contains(location, "accounts.google.com") || strings.Contains(location, "iap.googleapis.com") {
			return
		}
		t.Fatalf("%s redirected to %q, expected Google IAP login", description, location)
	}

	body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
	t.Fatalf("%s returned %s, expected IAP challenge or redirect: %s", description, resp.Status, strings.TrimSpace(string(body)))
}

func doRequestWithRetry(t *testing.T, client *http.Client, req *http.Request, description string) *http.Response {
	t.Helper()

	deadline := time.Now().Add(45 * time.Second)
	for {
		resp, err := client.Do(req.Clone(req.Context()))
		if err == nil {
			return resp
		}

		if time.Now().After(deadline) || !isRetryableHTTPGetError(err) {
			t.Fatalf("%s failed: %v", description, err)
		}

		time.Sleep(2 * time.Second)
	}
}

func trustedHTTPClient(t *testing.T, followRedirects bool) *http.Client {
	t.Helper()

	pool, err := x509.SystemCertPool()
	if err != nil {
		t.Fatalf("failed to load system cert pool: %v", err)
	}

	client := &http.Client{
		Timeout: 5 * time.Second,
		Transport: &http.Transport{
			TLSClientConfig: &tls.Config{RootCAs: pool, MinVersion: tls.VersionTLS12},
		},
	}
	if !followRedirects {
		client.CheckRedirect = func(_ *http.Request, _ []*http.Request) error {
			return http.ErrUseLastResponse
		}
	}
	return client
}

func routeHost(name string) string {
	if clusterProvider() == "gke" {
		return name + "." + strings.TrimSuffix(getenvDefaultForTests("GKE_DNS_DOMAIN", "gcp.kube"), ".")
	}
	return name + ".int.kube"
}

func isRetryableHTTPGetError(err error) bool {
	var dnsErr *net.DNSError
	if errors.As(err, &dnsErr) {
		return true
	}

	var netErr net.Error
	if errors.As(err, &netErr) {
		return true
	}

	return false
}

func httpbinRouteInstalled(t *testing.T) bool {
	t.Helper()

	if clusterProvider() == "gke" {
		return httpRouteInstalled(t, "httpbin", "https")
	}
	return httpRouteInstalled(t, "httpbin", "http")
}

func httpRouteInstalled(t *testing.T, namespace, name string) bool {
	t.Helper()

	output, err := runCommandE(defaultCommandTimeout, "kubectl", "get", "httproute", name, "-n", namespace, "-o", "name")
	if err != nil {
		warningf(t, "HTTPRoute %s/%s check skipped: %v", namespace, name, err)
		return false
	}
	return strings.TrimSpace(output) == "httproute.gateway.networking.k8s.io/"+name || strings.TrimSpace(output) == "httproute/"+name
}
