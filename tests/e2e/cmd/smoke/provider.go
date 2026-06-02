package main

import (
	"context"
	"fmt"
	"time"
)

type provider interface {
	preflight(context.Context) error
	create(context.Context, string, string, time.Duration) error
	delete(context.Context, string, string) error
	contextName(context.Context, string) (string, error)
}

func newProvider(name string) (provider, error) {
	switch name {
	case "local":
		return kindProvider{}, nil
	case "gke":
		return gkeProvider{}, nil
	case "vind":
		return vindProvider{}, nil
	default:
		return nil, fmt.Errorf("unsupported CLUSTER_PROVIDER %q", name)
	}
}
