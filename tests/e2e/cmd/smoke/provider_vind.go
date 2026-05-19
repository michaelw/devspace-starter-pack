package main

import (
	"context"
	"errors"
	"time"
)

type vindProvider struct{}

func (vindProvider) preflight(context.Context) error {
	return errors.New("E2E_CLUSTER_PROVIDER=vind is reserved for future support and is not implemented yet")
}

func (vindProvider) create(context.Context, string, string, time.Duration) error {
	return errors.New("E2E_CLUSTER_PROVIDER=vind is reserved for future support and is not implemented yet")
}

func (vindProvider) delete(context.Context, string, string) error {
	return nil
}

func (vindProvider) contextName(clusterName string) string {
	return clusterName
}
