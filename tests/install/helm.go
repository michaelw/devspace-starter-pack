package install_test

import (
	"fmt"
	"testing"
)

type helmRelease struct {
	Name       string `json:"name"`
	Namespace  string `json:"namespace"`
	Revision   string `json:"revision"`
	Status     string `json:"status"`
	Chart      string `json:"chart"`
	AppVersion string `json:"app_version"`
}

func assertHelmReleasesDeployed(t *testing.T) {
	t.Helper()

	releases := runJSON[[]helmRelease](t, "helm", "list", "-A", "-o", "json")
	if len(releases) == 0 {
		t.Fatal("no Helm releases found; run devspace deploy before running install diagnostics")
	}

	var failures []string
	for _, release := range releases {
		if release.Status != "deployed" {
			failures = append(failures, fmt.Sprintf("%s/%s is %q (chart %s revision %s)", release.Namespace, release.Name, release.Status, release.Chart, release.Revision))
		}
	}
	failWithList(t, "Helm releases are not deployed", failures)
}
