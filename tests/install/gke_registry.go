package install_test

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func assertOptionalGKERegistrySmoke(t *testing.T) {
	t.Helper()

	if os.Getenv("GKE_REGISTRY_SMOKE") != "1" {
		t.Skip("GKE_REGISTRY_SMOKE=1 is not set")
	}
	requireTools(t, "docker", "gcloud")

	prefix := gkeDevRegistryImagePrefix(t)
	tag := fmt.Sprintf("registry-smoke-%d", time.Now().UnixNano())
	imageName := strings.TrimSuffix(prefix, "/") + "/registry-smoke"
	image := imageName + ":" + tag

	dockerfile := filepath.Join(t.TempDir(), "Dockerfile")
	if err := os.WriteFile(dockerfile, []byte("FROM registry.k8s.io/pause:3.10\n"), 0o644); err != nil {
		t.Fatalf("write Dockerfile: %v", err)
	}

	runCommandWithTimeout(t, 2*time.Minute, "docker", "build", "--platform", "linux/amd64", "-t", image, filepath.Dir(dockerfile))
	defer func() {
		_, _ = runCommandE(30*time.Second, "docker", "rmi", image)
	}()

	runCommandWithTimeout(t, 5*time.Minute, "docker", "push", image)
	defer func() {
		_, _ = runCommandE(2*time.Minute, "gcloud", "artifacts", "docker", "images", "delete", imageName, "--quiet", "--delete-tags")
	}()

	namespace := "registry-smoke-" + tag
	runCommand(t, "kubectl", "create", "namespace", namespace)
	defer func() {
		_, _ = runCommandE(2*time.Minute, "kubectl", "delete", "namespace", namespace, "--wait=false")
	}()

	assertNoImagePullSecrets(t, namespace, "serviceaccount", "default")

	runCommand(t, "kubectl", "run", "registry-smoke", "-n", namespace, "--image", image, "--restart", "Never")
	runCommandWithTimeout(t, 3*time.Minute, "kubectl", "wait", "-n", namespace, "--for=condition=Ready", "pod/registry-smoke", "--timeout=180s")
	assertNoImagePullSecrets(t, namespace, "pod", "registry-smoke")
}

func gkeDevRegistryImagePrefix(t *testing.T) string {
	t.Helper()

	if value := os.Getenv("DEV_REGISTRY_IMAGE_PREFIX"); value != "" {
		return value
	}
	if value := os.Getenv("DEV_REGISTRY"); value != "" {
		return value
	}

	host := os.Getenv("DEV_REGISTRY_HOST")
	if host == "" {
		host = getenvDefaultForTests("GKE_REGION", "us-central1") + "-docker.pkg.dev"
	}
	projectID := os.Getenv("GKE_PROJECT_ID")
	if projectID == "" {
		t.Fatal("GKE_PROJECT_ID is required when DEV_REGISTRY_IMAGE_PREFIX and DEV_REGISTRY are not set")
	}
	return host + "/" + projectID + "/devspace-dev"
}

func assertNoImagePullSecrets(t *testing.T, namespace, kind, name string) {
	t.Helper()

	output := runCommand(t, "kubectl", "get", kind, name, "-n", namespace, "-o", "jsonpath={.imagePullSecrets}{.spec.imagePullSecrets}")
	if strings.TrimSpace(output) != "" {
		t.Fatalf("%s/%s/%s has imagePullSecrets configured: %s", namespace, kind, name, output)
	}
}
