package main

import (
	"context"
	"os"
	"time"
)

type kindProvider struct{}

func (kindProvider) preflight(ctx context.Context) error {
	if err := requireTool(ctx, "kind"); err != nil {
		return err
	}
	return requireTool(ctx, "kubectl")
}

func (kindProvider) create(ctx context.Context, clusterName, kubeconfig string, wait time.Duration) error {
	return runStep(ctx, os.Environ(), "kind", "create", "cluster", "--name", clusterName, "--kubeconfig", kubeconfig, "--wait", wait.String())
}

func (kindProvider) delete(ctx context.Context, clusterName, kubeconfig string) error {
	return runStep(ctx, os.Environ(), "kind", "delete", "cluster", "--name", clusterName, "--kubeconfig", kubeconfig)
}

func (kindProvider) contextName(_ context.Context, clusterName string) (string, error) {
	return "kind-" + clusterName, nil
}
