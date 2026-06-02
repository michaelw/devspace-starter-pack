package main

import (
	"context"
	"errors"
	"time"
)

type vindProvider struct{}

func (vindProvider) preflight(context.Context) error {
	return errors.New("CLUSTER_PROVIDER=vind is reserved for future support and is not implemented yet")
}

func (vindProvider) create(context.Context, string, string, time.Duration) error {
	return errors.New("CLUSTER_PROVIDER=vind is reserved for future support and is not implemented yet")
}

func (vindProvider) delete(context.Context, string, string) error {
	return nil
}

func (vindProvider) contextName(_ context.Context, clusterName string) (string, error) {
	return clusterName, nil
}
