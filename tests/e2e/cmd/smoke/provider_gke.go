package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

type gkeProvider struct{}

type terraformOutputValue struct {
	Value json.RawMessage `json:"value"`
}

type gkeTerraformOutputs struct {
	ProjectID                      string
	Region                         string
	ClusterName                    string
	DNSDomain                      string
	DNSNameServers                 []string
	DevRegistryHost                string
	DevRegistry                    string
	DevRegistryImagePrefix         string
	ExternalDNSServiceAccountEmail string
}

func (gkeProvider) preflight(ctx context.Context) error {
	for _, tool := range []string{"terraform", "gcloud", "kubectl", "devspace"} {
		if err := requireTool(ctx, tool); err != nil {
			return err
		}
	}
	return nil
}

func (gkeProvider) create(ctx context.Context, clusterName, kubeconfig string, _ time.Duration) error {
	tfDir := gkeTerraformDir()
	if err := runStepInDir(ctx, tfDir, os.Environ(), "terraform", "init", "-input=false"); err != nil {
		return err
	}

	applyArgs := append([]string{"apply", "-input=false", "-auto-approve"}, gkeTerraformVarArgs(clusterName)...)
	if err := runStepInDir(ctx, tfDir, os.Environ(), "terraform", applyArgs...); err != nil {
		return err
	}

	outputs, err := readGKEOutputs(ctx)
	if err != nil {
		return err
	}

	env := append(os.Environ(), "KUBECONFIG="+kubeconfig)
	if err := runStep(ctx, env, "gcloud", "container", "clusters", "get-credentials", outputs.ClusterName, "--region", outputs.Region, "--project", outputs.ProjectID); err != nil {
		return err
	}

	return nil
}

func (gkeProvider) delete(ctx context.Context, clusterName, kubeconfig string) error {
	tfDir := gkeTerraformDir()
	env := append(os.Environ(), "KUBECONFIG="+kubeconfig)
	if extraEnv, err := (gkeProvider{}).environment(ctx, kubeconfig); err == nil {
		env = append(env, extraEnv...)
	}

	if err := runStep(ctx, env, "devspace", "run", "reset-cluster-dns"); err != nil {
		fmt.Fprintf(os.Stderr, "smoke: warning: failed to reset GKE split DNS before destroy: %v\n", err)
	}

	destroyArgs := append([]string{"destroy", "-input=false", "-auto-approve"}, gkeTerraformVarArgs(clusterName)...)
	return runStepInDir(ctx, tfDir, os.Environ(), "terraform", destroyArgs...)
}

func (gkeProvider) contextName(ctx context.Context, _ string) (string, error) {
	outputs, err := readGKEOutputs(ctx)
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("gke_%s_%s_%s", outputs.ProjectID, outputs.Region, outputs.ClusterName), nil
}

func (gkeProvider) environment(ctx context.Context, _ string) ([]string, error) {
	outputs, err := readGKEOutputs(ctx)
	if err != nil {
		return nil, err
	}

	domain := strings.TrimSuffix(outputs.DNSDomain, ".")
	return []string{
		"GKE_PROJECT_ID=" + outputs.ProjectID,
		"GKE_REGION=" + outputs.Region,
		"GKE_DNS_DOMAIN=" + domain,
		"DNS_DOMAIN=" + domain,
		"GKE_DNS_NAMESERVERS=" + strings.Join(outputs.DNSNameServers, ","),
		"DEV_REGISTRY_HOST=" + outputs.DevRegistryHost,
		"DEV_REGISTRY=" + outputs.DevRegistry,
		"DEV_REGISTRY_IMAGE_PREFIX=" + outputs.DevRegistryImagePrefix,
		"GATEWAY_NAMESPACE=gke-gateway",
		"GATEWAY_PROVIDER=gke-gateway",
		"DNS_MODE=cloud-dns",
		"DNS_SERVICE_ID=gcp-kube",
		"CLUSTER_PROVIDER=gke",
	}, nil
}

func gkeTerraformDir() string {
	if value := os.Getenv("GKE_TF_DIR"); value != "" {
		return value
	}
	return filepath.Join("infra", "gcp-ephemeral")
}

func gkeTerraformVarArgs(clusterName string) []string {
	args := []string{"-var", "cluster_name=" + clusterName}
	if value := os.Getenv("GKE_TF_VAR_FILE"); value != "" {
		args = append(args, "-var-file", value)
	}
	return args
}

func readGKEOutputs(ctx context.Context) (gkeTerraformOutputs, error) {
	output, err := commandOutputInDir(ctx, gkeTerraformDir(), os.Environ(), "terraform", "output", "-json")
	if err != nil {
		return gkeTerraformOutputs{}, err
	}

	var raw map[string]terraformOutputValue
	if err := json.Unmarshal([]byte(output), &raw); err != nil {
		return gkeTerraformOutputs{}, fmt.Errorf("parse terraform output -json: %w", err)
	}

	var outputs gkeTerraformOutputs
	if err := decodeTerraformOutput(raw, "project_id", &outputs.ProjectID); err != nil {
		return outputs, err
	}
	if err := decodeTerraformOutput(raw, "region", &outputs.Region); err != nil {
		return outputs, err
	}
	if err := decodeTerraformOutput(raw, "cluster_name", &outputs.ClusterName); err != nil {
		return outputs, err
	}
	if err := decodeTerraformOutput(raw, "dns_domain", &outputs.DNSDomain); err != nil {
		return outputs, err
	}
	if err := decodeTerraformOutput(raw, "dns_name_servers", &outputs.DNSNameServers); err != nil {
		return outputs, err
	}
	if err := decodeTerraformOutput(raw, "dev_registry_host", &outputs.DevRegistryHost); err != nil {
		return outputs, err
	}
	if err := decodeTerraformOutput(raw, "dev_registry", &outputs.DevRegistry); err != nil {
		return outputs, err
	}
	if err := decodeTerraformOutput(raw, "dev_registry_image_prefix", &outputs.DevRegistryImagePrefix); err != nil {
		return outputs, err
	}
	if err := decodeTerraformOutput(raw, "external_dns_service_account_email", &outputs.ExternalDNSServiceAccountEmail); err != nil {
		return outputs, err
	}
	return outputs, nil
}

func decodeTerraformOutput[T any](raw map[string]terraformOutputValue, name string, target *T) error {
	value, ok := raw[name]
	if !ok {
		return fmt.Errorf("terraform output %q is missing", name)
	}
	if err := json.Unmarshal(value.Value, target); err != nil {
		return fmt.Errorf("parse terraform output %q: %w", name, err)
	}
	return nil
}

func runStepInDir(ctx context.Context, dir string, env []string, name string, args ...string) error {
	fmt.Printf("smoke: running %s %s in %s\n", name, strings.Join(args, " "), dir)
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Dir = dir
	cmd.Env = append(env, "TF_IN_AUTOMATION=1")
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

func commandOutputInDir(ctx context.Context, dir string, env []string, name string, args ...string) (string, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Dir = dir
	cmd.Env = append(env, "TF_IN_AUTOMATION=1")
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return stdout.String(), fmt.Errorf("%s %s failed: %w\nstdout:\n%s\nstderr:\n%s", name, strings.Join(args, " "), err, stdout.String(), stderr.String())
	}
	return stdout.String(), nil
}
