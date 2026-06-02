package main

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

const (
	defaultProvider            = "local"
	defaultTimeout             = 20 * time.Minute
	defaultClusterCreateWait   = 5 * time.Minute
	defaultCleanupTimeout      = 5 * time.Minute
	defaultReadyTimeout        = 5 * time.Minute
	defaultReadyReportInterval = time.Minute
	defaultDiagnosticTimeout   = 45 * time.Second
	defaultTestTimeout         = 5 * time.Minute
)

type config struct {
	providerName string
	clusterName  string
	keepCluster  bool
	devspaceArgs []string
	testArgs     []string

	timeout             time.Duration
	clusterCreateWait   time.Duration
	cleanupTimeout      time.Duration
	readyTimeout        time.Duration
	readyReportInterval time.Duration
	diagnosticTimeout   time.Duration
	testTimeout         time.Duration
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintf(os.Stderr, "smoke failed: %v\n", err)
		os.Exit(1)
	}
}

func run() error {
	cfg := loadConfig()
	provider, err := newProvider(cfg.providerName)
	if err != nil {
		return err
	}

	ctx, cancel := context.WithTimeout(context.Background(), cfg.timeout)
	defer cancel()

	tempDir, err := os.MkdirTemp("", "devspace-starter-pack-smoke-*")
	if err != nil {
		return fmt.Errorf("create temp directory: %w", err)
	}
	removeTempDir := true
	defer func() {
		if removeTempDir {
			_ = os.RemoveAll(tempDir)
		}
	}()

	kubeconfig := filepath.Join(tempDir, "kubeconfig")
	fmt.Printf("smoke: provider=%s cluster=%s kubeconfig=%s\n", cfg.providerName, cfg.clusterName, kubeconfig)

	if err := provider.preflight(ctx); err != nil {
		return err
	}
	if err := provider.create(ctx, cfg.clusterName, kubeconfig, cfg.clusterCreateWait); err != nil {
		return err
	}

	clusterCreated := true
	defer func() {
		if !clusterCreated {
			return
		}
		if cfg.keepCluster {
			removeTempDir = false
			fmt.Printf("smoke: preserving cluster %q and kubeconfig %s because E2E_KEEP_CLUSTER=1\n", cfg.clusterName, kubeconfig)
			return
		}
		cleanupCtx, cancel := context.WithTimeout(context.Background(), cfg.cleanupTimeout)
		defer cancel()
		if err := provider.delete(cleanupCtx, cfg.clusterName, kubeconfig); err != nil {
			fmt.Fprintf(os.Stderr, "smoke: failed to delete cluster %q: %v\n", cfg.clusterName, err)
		}
	}()

	env := append(os.Environ(), "KUBECONFIG="+kubeconfig)
	if envProvider, ok := provider.(interface {
		environment(context.Context, string) ([]string, error)
	}); ok {
		extraEnv, err := envProvider.environment(ctx, kubeconfig)
		if err != nil {
			return err
		}
		env = append(env, extraEnv...)
	}
	expectedContext, err := provider.contextName(ctx, cfg.clusterName)
	if err != nil {
		return err
	}
	if err := assertContext(ctx, env, expectedContext); err != nil {
		return err
	}

	if err := runStep(ctx, env, "devspace", append([]string{"deploy"}, cfg.devspaceArgs...)...); err != nil {
		collectDiagnostics(env, cfg.diagnosticTimeout)
		return err
	}

	if err := waitForPodsReady(ctx, env, cfg); err != nil {
		collectDiagnostics(env, cfg.diagnosticTimeout)
		return err
	}

	testEnv := append(env, "CGO_ENABLED=1", "CLUSTER_PROVIDER="+cfg.providerName)
	goArgs := append([]string{"test", "-count=1", "-timeout", cfg.testTimeout.String()}, cfg.testArgs...)
	goArgs = append(goArgs, "./tests/install")
	if output, err := runStepCapture(ctx, testEnv, "go", goArgs...); err != nil {
		collectDiagnostics(env, cfg.diagnosticTimeout)
		summary := formatInstallTestOutputSummary(output)
		if summary != "" {
			writeStepSummary(summary)
			fmt.Fprintln(os.Stderr, summary)
		}
		return err
	}

	fmt.Println("smoke: completed successfully")
	return nil
}

func waitForPodsReady(ctx context.Context, env []string, cfg config) error {
	waitCtx, cancel := context.WithTimeout(ctx, cfg.readyTimeout)
	defer cancel()

	ticker := time.NewTicker(cfg.readyReportInterval)
	defer ticker.Stop()

	for {
		if notReady, ready, err := podReadiness(waitCtx, env); err != nil {
			return err
		} else if ready {
			fmt.Println("smoke: all pods are Ready")
			return nil
		} else if len(notReady) == 0 {
			fmt.Println("smoke: waiting for pods to be created")
		}

		select {
		case <-waitCtx.Done():
			fmt.Fprintln(os.Stderr, "smoke: timed out waiting for all pods to become Ready")
			printPendingPodDiagnostics(env, cfg.diagnosticTimeout)
			return waitCtx.Err()
		case <-ticker.C:
			printPodStatus(env)
		}
	}
}

func podReadiness(ctx context.Context, env []string) ([]string, bool, error) {
	output, err := commandOutput(ctx, env, "kubectl", "get", "pods", "--all-namespaces", "--no-headers")
	if err != nil {
		return nil, false, err
	}
	output = strings.TrimSpace(output)
	if output == "" {
		return nil, false, nil
	}
	var notReady []string
	for _, line := range strings.Split(output, "\n") {
		fields := strings.Fields(line)
		if len(fields) < 4 {
			continue
		}
		if fields[3] == "Completed" || fields[3] == "Succeeded" {
			continue
		}
		readyParts := strings.SplitN(fields[2], "/", 2)
		if len(readyParts) != 2 || readyParts[0] != readyParts[1] || fields[3] != "Running" {
			notReady = append(notReady, line)
		}
	}
	return notReady, len(notReady) == 0, nil
}

func printPodStatus(env []string) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	notReady, ready, err := podReadiness(ctx, env)
	if err != nil {
		fmt.Fprintf(os.Stderr, "smoke: failed to list pod readiness: %v\n", err)
		return
	}
	if ready {
		fmt.Println("smoke: all pods are Ready")
		return
	}
	if len(notReady) == 0 {
		fmt.Println("smoke: waiting for pods to be created")
		return
	}
	fmt.Printf("smoke: waiting for %d non-ready pod(s)\n", len(notReady))
	for _, line := range notReady {
		fmt.Printf("smoke: non-ready pod: %s\n", line)
	}
}

func printPendingPodDiagnostics(env []string, timeout time.Duration) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()

	_ = runStep(ctx, env, "kubectl", "get", "pods", "--all-namespaces", "-o", "wide")
	_ = runStep(ctx, env, "kubectl", "get", "events", "--all-namespaces", "--sort-by=.lastTimestamp")
	_ = runStep(ctx, env, "kubectl", "describe", "pods", "--all-namespaces")
}

func loadConfig() config {
	providerName := getenvDefault("CLUSTER_PROVIDER", defaultProvider)
	clusterName := os.Getenv("E2E_CLUSTER_NAME")
	if clusterName == "" {
		clusterName = fmt.Sprintf("devspace-smoke-%d", time.Now().Unix())
	}

	devspaceArgs := splitArgs(os.Getenv("E2E_DEVSPACE_ARGS"))
	if providerName == "gke" && len(devspaceArgs) == 0 {
		devspaceArgs = []string{"--profile", "with-test"}
	}

	return config{
		providerName: providerName,
		clusterName:  clusterName,
		keepCluster:  os.Getenv("E2E_KEEP_CLUSTER") == "1",
		devspaceArgs: devspaceArgs,
		testArgs:     splitArgs(os.Getenv("E2E_TEST_ARGS")),

		timeout:             durationFromEnv("E2E_TIMEOUT", defaultTimeout),
		clusterCreateWait:   durationFromEnv("E2E_CLUSTER_CREATE_WAIT", defaultClusterCreateWait),
		cleanupTimeout:      durationFromEnv("E2E_CLEANUP_TIMEOUT", defaultCleanupTimeout),
		readyTimeout:        durationFromEnv("E2E_READY_TIMEOUT", defaultReadyTimeout),
		readyReportInterval: durationFromEnv("E2E_READY_REPORT_INTERVAL", defaultReadyReportInterval),
		diagnosticTimeout:   durationFromEnv("E2E_DIAGNOSTIC_TIMEOUT", defaultDiagnosticTimeout),
		testTimeout:         durationFromEnv("E2E_TEST_TIMEOUT", defaultTestTimeout),
	}
}

func assertContext(ctx context.Context, env []string, expected string) error {
	output, err := commandOutput(ctx, env, "kubectl", "config", "current-context")
	if err != nil {
		return err
	}
	got := strings.TrimSpace(output)
	if got != expected {
		return fmt.Errorf("kubectl current-context is %q, expected ephemeral context %q", got, expected)
	}
	return runStep(ctx, env, "kubectl", "cluster-info")
}

func collectDiagnostics(env []string, timeout time.Duration) {
	fmt.Fprintln(os.Stderr, "smoke: collecting Kubernetes diagnostics")
	diagnosticSteps := [][]string{
		{"kubectl", "get", "pods", "--all-namespaces", "-o", "wide"},
		{"kubectl", "get", "svc", "--all-namespaces", "-o", "wide"},
		{"kubectl", "get", "events", "--all-namespaces", "--sort-by=.lastTimestamp"},
		{"kubectl", "describe", "pods", "--all-namespaces"},
		{"helm", "list", "--all-namespaces"},
	}

	for _, step := range diagnosticSteps {
		ctx, cancel := context.WithTimeout(context.Background(), timeout)
		_ = runStep(ctx, env, step[0], step[1:]...)
		cancel()
	}
}

func requireTool(ctx context.Context, tool string) error {
	_, err := exec.LookPath(tool)
	if err != nil {
		return fmt.Errorf("required tool %q is not available in PATH", tool)
	}
	return nil
}

func runStep(ctx context.Context, env []string, name string, args ...string) error {
	fmt.Printf("smoke: running %s %s\n", name, strings.Join(args, " "))
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Env = env
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		if ctx.Err() != nil {
			return fmt.Errorf("%s %s timed out: %w", name, strings.Join(args, " "), ctx.Err())
		}
		return fmt.Errorf("%s %s failed: %w", name, strings.Join(args, " "), err)
	}
	return nil
}

func runStepCapture(ctx context.Context, env []string, name string, args ...string) (string, error) {
	fmt.Printf("smoke: running %s %s\n", name, strings.Join(args, " "))
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Env = env

	var output bytes.Buffer
	cmd.Stdout = io.MultiWriter(os.Stdout, &output)
	cmd.Stderr = io.MultiWriter(os.Stderr, &output)

	if err := cmd.Run(); err != nil {
		if ctx.Err() != nil {
			return output.String(), fmt.Errorf("%s %s timed out: %w", name, strings.Join(args, " "), ctx.Err())
		}
		return output.String(), fmt.Errorf("%s %s failed: %w", name, strings.Join(args, " "), err)
	}

	return output.String(), nil
}

func commandOutput(ctx context.Context, env []string, name string, args ...string) (string, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Env = env
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return stdout.String(), fmt.Errorf("%s %s failed: %w\nstdout:\n%s\nstderr:\n%s", name, strings.Join(args, " "), err, stdout.String(), stderr.String())
	}
	return stdout.String(), nil
}

func formatInstallTestOutputSummary(output string) string {
	output = strings.TrimSpace(output)
	if output == "" {
		return ""
	}

	var b strings.Builder
	b.WriteString("## Install test output\n\n```text\n")
	b.WriteString(output)
	b.WriteString("\n```")
	return b.String()
}

func writeStepSummary(summary string) {
	path := os.Getenv("GITHUB_STEP_SUMMARY")
	if path == "" || summary == "" {
		return
	}

	file, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		fmt.Fprintf(os.Stderr, "smoke: failed to write GitHub step summary: %v\n", err)
		return
	}
	defer file.Close()

	if _, err := file.WriteString(summary + "\n"); err != nil {
		fmt.Fprintf(os.Stderr, "smoke: failed to append GitHub step summary: %v\n", err)
	}
}

func splitArgs(value string) []string {
	return strings.Fields(value)
}

func getenvDefault(name, fallback string) string {
	value := os.Getenv(name)
	if value == "" {
		return fallback
	}
	return value
}

func durationFromEnv(name string, fallback time.Duration) time.Duration {
	value := os.Getenv(name)
	if value == "" {
		return fallback
	}
	duration, err := time.ParseDuration(value)
	if err != nil {
		fmt.Fprintf(os.Stderr, "smoke: invalid duration %s=%q, using %s\n", name, value, fallback)
		return fallback
	}
	return duration
}
