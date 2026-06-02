package install_test

import (
	"context"
	"fmt"
	"net"
	"sort"
	"strings"
	"testing"
	"time"
)

func assertDirectDNSResolves(t *testing.T, nameserverIP, name, expectedIP string) {
	t.Helper()

	resolverAddress := net.JoinHostPort(nameserverIP, "53")
	resolver := &net.Resolver{
		PreferGo: true,
		Dial: func(ctx context.Context, network, address string) (net.Conn, error) {
			dialer := net.Dialer{Timeout: 3 * time.Second}
			return dialer.DialContext(ctx, "udp", resolverAddress)
		},
	}

	ips := lookupHost(t, resolver, name, "direct CoreDNS resolver "+resolverAddress)
	if !containsIP(ips, expectedIP) {
		t.Fatalf("direct DNS query for %s through %s resolved %v, expected %s", name, nameserverIP, ips, expectedIP)
	}
}

func assertDefaultResolverResolves(t *testing.T, name, expectedIP string) {
	t.Helper()

	ips := lookupHost(t, net.DefaultResolver, name, "host system resolver")
	if !containsIP(ips, expectedIP) {
		t.Fatalf("host resolver query for %s resolved %v, expected %s", name, ips, expectedIP)
	}
}

func assertCloudDNSResolves(t *testing.T, nameservers, name, expectedIP string) {
	t.Helper()

	nameserverIP := firstNameserverIP(t, nameservers)
	assertDirectDNSResolves(t, nameserverIP, name, expectedIP)
}

func firstNameserverIP(t *testing.T, nameservers string) string {
	t.Helper()

	for _, ns := range strings.Fields(strings.ReplaceAll(nameservers, ",", " ")) {
		ns = strings.TrimSuffix(ns, ".") + "."
		ips := lookupHost(t, net.DefaultResolver, ns, "default resolver for Cloud DNS nameserver")
		for _, ip := range ips {
			if strings.Contains(ip, ".") {
				return ip
			}
		}
	}

	t.Fatalf("GKE_DNS_NAMESERVERS did not contain a nameserver with an IPv4 address: %q", nameservers)
	return ""
}

func lookupHost(t *testing.T, resolver *net.Resolver, name, description string) []string {
	t.Helper()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	ips, err := resolver.LookupHost(ctx, name)
	if err != nil {
		t.Fatalf("failed to resolve %s using %s: %v", name, description, err)
	}
	sort.Strings(ips)
	return ips
}

func containsIP(ips []string, expected string) bool {
	for _, ip := range ips {
		if ip == expected {
			return true
		}
	}
	return false
}

func resolverMismatch(name, got, expected string) string {
	return fmt.Sprintf("%s resolver nameserver is %s, expected %s", name, got, expected)
}
