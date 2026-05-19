//go:build !darwin && !linux

package install_test

import "testing"

func hostRequiredTools() []string {
	return nil
}

func assertHostDNS(t *testing.T, name, expectedIP string) {
	t.Helper()
	t.Skipf("host DNS integration checks for %s -> %s are currently implemented only on macOS", name, expectedIP)
}

func assertRootCAImported(t *testing.T) {
	t.Helper()
	t.Skip("system Keychain certificate import checks are currently implemented only on macOS")
}

func assertOptionalHTTPSRoute(t *testing.T) {
	t.Helper()
	t.Skip("optional HTTPS route checks are currently implemented only on macOS")
}

func assertOptionalTracingRoute(t *testing.T) {
	t.Helper()
	t.Skip("optional Jaeger HTTPS route checks are currently implemented only on macOS")
}

func assertOptionalGrafanaRoute(t *testing.T) {
	t.Helper()
	t.Skip("optional Grafana HTTPS route checks are currently implemented only on macOS")
}
