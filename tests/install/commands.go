package install_test

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os/exec"
	"strings"
	"testing"
	"time"

	"github.com/gruntwork-io/terratest/modules/shell"
)

const defaultCommandTimeout = 30 * time.Second

func requireTools(t *testing.T, tools ...string) {
	t.Helper()

	for _, tool := range tools {
		_, err := shell.RunCommandAndGetOutputE(t, shell.Command{
			Command: "sh",
			Args:    []string{"-c", "command -v " + shellQuote(tool)},
		})
		if err != nil {
			t.Fatalf("required tool %q is not available in PATH: %v", tool, err)
		}
	}
}

func runCommand(t *testing.T, name string, args ...string) string {
	t.Helper()
	return runCommandWithTimeout(t, defaultCommandTimeout, name, args...)
}

func runCommandWithTimeout(t *testing.T, timeout time.Duration, name string, args ...string) string {
	t.Helper()

	output, err := runCommandE(timeout, name, args...)
	if err != nil {
		t.Fatal(err)
	}
	return output
}

func runCommandE(timeout time.Duration, name string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, name, args...)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	err := cmd.Run()
	if ctx.Err() == context.DeadlineExceeded {
		return stdout.String(), fmt.Errorf("%s %s timed out after %s", name, strings.Join(args, " "), timeout)
	}
	if err != nil {
		return stdout.String(), fmt.Errorf("%s %s failed: %w\nstdout:\n%s\nstderr:\n%s", name, strings.Join(args, " "), err, stdout.String(), stderr.String())
	}

	return stdout.String(), nil
}

func runJSON[T any](t *testing.T, name string, args ...string) T {
	t.Helper()

	output := runCommand(t, name, args...)
	var value T
	if err := json.Unmarshal([]byte(output), &value); err != nil {
		t.Fatalf("failed to parse JSON from %s %s: %v\noutput:\n%s", name, strings.Join(args, " "), err, output)
	}
	return value
}

func kubectlJSON[T any](t *testing.T, args ...string) T {
	t.Helper()

	fullArgs := append([]string{}, args...)
	fullArgs = append(fullArgs, "-o", "json")
	return runJSON[T](t, "kubectl", fullArgs...)
}

func requireKubernetesContext(t *testing.T) {
	t.Helper()

	contextName := strings.TrimSpace(runCommand(t, "kubectl", "config", "current-context"))
	if contextName == "" {
		t.Fatal("kubectl current context is empty")
	}
	t.Logf("using Kubernetes context %q", contextName)
	runCommand(t, "kubectl", "version", "--request-timeout=10s")
}

func shellQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "'\"'\"'") + "'"
}

func failWithList(t *testing.T, title string, failures []string) {
	t.Helper()
	if len(failures) == 0 {
		return
	}

	t.Fatalf("%s:\n- %s", title, strings.Join(failures, "\n- "))
}

func warningf(t *testing.T, format string, args ...any) {
	t.Helper()
	t.Logf("warning: "+format, args...)
}

func describeObject(namespace, kind, name string) string {
	if namespace == "" {
		return fmt.Sprintf("%s/%s", kind, name)
	}
	return fmt.Sprintf("%s/%s/%s", namespace, kind, name)
}
