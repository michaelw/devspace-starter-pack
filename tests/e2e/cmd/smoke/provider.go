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
	contextName(string) string
}

func newProvider(name string) (provider, error) {
	switch name {
	case "kind":
		return kindProvider{}, nil
	case "vind":
		return vindProvider{}, nil
	default:
		return nil, fmt.Errorf("unsupported E2E_CLUSTER_PROVIDER %q", name)
	}
}
