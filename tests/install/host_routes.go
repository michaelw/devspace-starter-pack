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
