package install_test

import (
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/pem"
	"fmt"
	"strings"
	"testing"

	"gopkg.in/yaml.v3"
)

type metadata struct {
	Name      string            `json:"name"`
	Namespace string            `json:"namespace"`
	Labels    map[string]string `json:"labels"`
}

type deploymentList struct {
	Items []deployment `json:"items"`
}

type deployment struct {
	Metadata metadata `json:"metadata"`
	Spec     struct {
		Replicas *int `json:"replicas"`
	} `json:"spec"`
	Status struct {
		ReadyReplicas     int `json:"readyReplicas"`
		AvailableReplicas int `json:"availableReplicas"`
		UpdatedReplicas   int `json:"updatedReplicas"`
	} `json:"status"`
}

type statefulSetList struct {
	Items []statefulSet `json:"items"`
}

type statefulSet struct {
	Metadata metadata `json:"metadata"`
	Spec     struct {
		Replicas *int `json:"replicas"`
	} `json:"spec"`
	Status struct {
		ReadyReplicas   int `json:"readyReplicas"`
		UpdatedReplicas int `json:"updatedReplicas"`
	} `json:"status"`
}

type daemonSetList struct {
	Items []daemonSet `json:"items"`
}

type daemonSet struct {
	Metadata metadata `json:"metadata"`
	Status   struct {
		DesiredNumberScheduled int `json:"desiredNumberScheduled"`
		NumberReady            int `json:"numberReady"`
		UpdatedNumberScheduled int `json:"updatedNumberScheduled"`
	} `json:"status"`
}

type podList struct {
	Items []pod `json:"items"`
}

type pod struct {
	Metadata metadata `json:"metadata"`
	Status   struct {
		Phase             string            `json:"phase"`
		Conditions        []podCondition    `json:"conditions"`
		ContainerStatuses []containerStatus `json:"containerStatuses"`
	} `json:"status"`
}

type podCondition struct {
	Type   string `json:"type"`
	Status string `json:"status"`
}

type containerStatus struct {
	Name  string `json:"name"`
	Ready bool   `json:"ready"`
	State struct {
		Waiting *struct {
			Reason  string `json:"reason"`
			Message string `json:"message"`
		} `json:"waiting"`
		Terminated *struct {
			Reason   string `json:"reason"`
			Message  string `json:"message"`
			ExitCode int    `json:"exitCode"`
		} `json:"terminated"`
	} `json:"state"`
}

type serviceList struct {
	Items []service `json:"items"`
}

type service struct {
	Metadata metadata `json:"metadata"`
	Spec     struct {
		Type         string            `json:"type"`
		ClusterIP    string            `json:"clusterIP"`
		Selector     map[string]string `json:"selector"`
		ExternalName string            `json:"externalName"`
		Ports        []servicePort     `json:"ports"`
	} `json:"spec"`
	Status struct {
		LoadBalancer struct {
			Ingress []loadBalancerIngress `json:"ingress"`
		} `json:"loadBalancer"`
	} `json:"status"`
}

type servicePort struct {
	Name string `json:"name"`
	Port int    `json:"port"`
}

type loadBalancerIngress struct {
	IP       string `json:"ip"`
	Hostname string `json:"hostname"`
}

type endpointSliceList struct {
	Items []endpointSlice `json:"items"`
}

type endpointSlice struct {
	Metadata  metadata   `json:"metadata"`
	Endpoints []endpoint `json:"endpoints"`
}

type endpoint struct {
	Addresses  []string `json:"addresses"`
	Conditions struct {
		Ready *bool `json:"ready"`
	} `json:"conditions"`
}

type condition struct {
	Type    string `json:"type"`
	Status  string `json:"status"`
	Reason  string `json:"reason"`
	Message string `json:"message"`
}

type certificateList struct {
	Items []certResource `json:"items"`
}

type issuerList struct {
	Items []certResource `json:"items"`
}

type certResource struct {
	Metadata metadata `json:"metadata"`
	Status   struct {
		Conditions []condition `json:"conditions"`
	} `json:"status"`
}

type secret struct {
	Data map[string]string `json:"data"`
}

type configMap struct {
	Data map[string]string `json:"data"`
}

type istioMeshConfig struct {
	DefaultConfig struct {
		ProxyStatsMatcher struct {
			InclusionRegexps []string `yaml:"inclusionRegexps"`
		} `yaml:"proxyStatsMatcher"`
	} `yaml:"defaultConfig"`
	ExtensionProviders []istioExtensionProvider `yaml:"extensionProviders"`
}

type istioExtensionProvider struct {
	Name              string `yaml:"name"`
	OpenTelemetry     any    `yaml:"opentelemetry"`
	EnvoyExtAuthzGRPC *struct {
		Service                      string   `yaml:"service"`
		Port                         int      `yaml:"port"`
		Timeout                      string   `yaml:"timeout"`
		IncludeRequestHeadersInCheck []string `yaml:"includeRequestHeadersInCheck"`
		HeadersToUpstreamOnAllow     []string `yaml:"headersToUpstreamOnAllow"`
		HeadersToDownstreamOnDeny    []string `yaml:"headersToDownstreamOnDeny"`
	} `yaml:"envoyExtAuthzGrpc"`
}

const gatewayExtAuthzProviderName = "gateway-ext-authz-grpc"

func assertWorkloadsReady(t *testing.T, namespaces []string) {
	t.Helper()

	var failures []string

	deployments := kubectlJSON[deploymentList](t, "get", "deployments", "-A")
	for _, item := range deployments.Items {
		if !namespaceChecked(item.Metadata.Namespace, namespaces) {
			continue
		}
		desired := desiredReplicas(item.Spec.Replicas)
		if item.Status.ReadyReplicas != desired || item.Status.AvailableReplicas != desired || item.Status.UpdatedReplicas != desired {
			failures = append(failures, fmt.Sprintf("%s wants %d replicas, ready=%d available=%d updated=%d",
				describeObject(item.Metadata.Namespace, "deployment", item.Metadata.Name), desired, item.Status.ReadyReplicas, item.Status.AvailableReplicas, item.Status.UpdatedReplicas))
		}
	}

	statefulSets := kubectlJSON[statefulSetList](t, "get", "statefulsets", "-A")
	for _, item := range statefulSets.Items {
		if !namespaceChecked(item.Metadata.Namespace, namespaces) {
			continue
		}
		desired := desiredReplicas(item.Spec.Replicas)
		if item.Status.ReadyReplicas != desired || item.Status.UpdatedReplicas != desired {
			failures = append(failures, fmt.Sprintf("%s wants %d replicas, ready=%d updated=%d",
				describeObject(item.Metadata.Namespace, "statefulset", item.Metadata.Name), desired, item.Status.ReadyReplicas, item.Status.UpdatedReplicas))
		}
	}

	daemonSets := kubectlJSON[daemonSetList](t, "get", "daemonsets", "-A")
	for _, item := range daemonSets.Items {
		if !namespaceChecked(item.Metadata.Namespace, namespaces) {
			continue
		}
		if item.Status.NumberReady != item.Status.DesiredNumberScheduled || item.Status.UpdatedNumberScheduled != item.Status.DesiredNumberScheduled {
			failures = append(failures, fmt.Sprintf("%s wants %d scheduled pods, ready=%d updated=%d",
				describeObject(item.Metadata.Namespace, "daemonset", item.Metadata.Name), item.Status.DesiredNumberScheduled, item.Status.NumberReady, item.Status.UpdatedNumberScheduled))
		}
	}

	failWithList(t, "workloads are not ready", failures)
}

func assertPodsReady(t *testing.T, namespaces []string) {
	t.Helper()

	pods := kubectlJSON[podList](t, "get", "pods", "-A")
	var failures []string

	for _, item := range pods.Items {
		if !namespaceChecked(item.Metadata.Namespace, namespaces) {
			continue
		}
		if item.Status.Phase != "Running" && item.Status.Phase != "Succeeded" {
			failures = append(failures, fmt.Sprintf("%s has phase %s", describeObject(item.Metadata.Namespace, "pod", item.Metadata.Name), item.Status.Phase))
		}
		if !podReady(item) && item.Status.Phase != "Succeeded" {
			failures = append(failures, fmt.Sprintf("%s is not Ready", describeObject(item.Metadata.Namespace, "pod", item.Metadata.Name)))
		}
		for _, container := range item.Status.ContainerStatuses {
			if container.State.Waiting != nil && isBadWaitingReason(container.State.Waiting.Reason) {
				failures = append(failures, fmt.Sprintf("%s container %s is waiting: %s %s",
					describeObject(item.Metadata.Namespace, "pod", item.Metadata.Name), container.Name, container.State.Waiting.Reason, container.State.Waiting.Message))
			}
			if container.State.Terminated != nil && container.State.Terminated.ExitCode != 0 && item.Status.Phase != "Succeeded" {
				failures = append(failures, fmt.Sprintf("%s container %s terminated with exit code %d: %s %s",
					describeObject(item.Metadata.Namespace, "pod", item.Metadata.Name), container.Name, container.State.Terminated.ExitCode, container.State.Terminated.Reason, container.State.Terminated.Message))
			}
		}
	}

	failWithList(t, "pods are not healthy", failures)
}

func assertServicesHaveReadyEndpoints(t *testing.T, namespaces []string) {
	t.Helper()

	services := kubectlJSON[serviceList](t, "get", "services", "-A")
	slices := kubectlJSON[endpointSliceList](t, "get", "endpointslices.discovery.k8s.io", "-A")
	readyByService := map[string]int{}
	for _, slice := range slices.Items {
		serviceName := slice.Metadata.Labels["kubernetes.io/service-name"]
		if serviceName == "" {
			continue
		}
		key := serviceKey(slice.Metadata.Namespace, serviceName)
		for _, endpoint := range slice.Endpoints {
			if endpointReady(endpoint) {
				readyByService[key] += len(endpoint.Addresses)
			}
		}
	}

	var failures []string
	for _, svc := range services.Items {
		if !namespaceChecked(svc.Metadata.Namespace, namespaces) {
			continue
		}
		if svc.Spec.Type == "ExternalName" || svc.Spec.ClusterIP == "None" || len(svc.Spec.Selector) == 0 {
			continue
		}
		if readyByService[serviceKey(svc.Metadata.Namespace, svc.Metadata.Name)] == 0 {
			failures = append(failures, fmt.Sprintf("%s has no ready EndpointSlice addresses", describeObject(svc.Metadata.Namespace, "service", svc.Metadata.Name)))
		}
	}

	failWithList(t, "services are missing ready endpoints", failures)
}

func assertLoadBalancersAssigned(t *testing.T, namespaces []string) {
	t.Helper()

	services := kubectlJSON[serviceList](t, "get", "services", "-A")
	var failures []string
	for _, svc := range services.Items {
		if !namespaceChecked(svc.Metadata.Namespace, namespaces) || svc.Spec.Type != "LoadBalancer" {
			continue
		}
		if loadBalancerAddress(svc) == "" {
			failures = append(failures, fmt.Sprintf("%s has no LoadBalancer ingress", describeObject(svc.Metadata.Namespace, "service", svc.Metadata.Name)))
		}
	}
	failWithList(t, "LoadBalancer services are not assigned", failures)
}

func assertServiceExposesPorts(t *testing.T, namespace, name string, expected map[string]int) {
	t.Helper()

	svc := kubectlJSON[service](t, "get", "service", name, "-n", namespace)
	actual := map[string]int{}
	for _, port := range svc.Spec.Ports {
		actual[port.Name] = port.Port
	}

	var failures []string
	for portName, portNumber := range expected {
		if actual[portName] != portNumber {
			failures = append(failures, fmt.Sprintf("%s port %s is %d, expected %d",
				describeObject(namespace, "service", name), portName, actual[portName], portNumber))
		}
	}
	failWithList(t, "service ports are not exposed", failures)
}

func assertConfigMapInstalled(t *testing.T, namespace, name string) {
	t.Helper()

	cm := kubectlJSON[configMap](t, "get", "configmap", name, "-n", namespace)
	if len(cm.Data) == 0 {
		t.Fatalf("%s has no data", describeObject(namespace, "configmap", name))
	}
}

func assertIstioGatewayExtAuthzHookInstalled(t *testing.T) {
	t.Helper()

	mesh := requireIstioMeshConfig(t)
	otelProvider := findIstioExtensionProvider(mesh, "otel-tracing")
	if otelProvider == nil || otelProvider.OpenTelemetry == nil {
		t.Fatal("Istio meshConfig is missing otel-tracing extension provider")
	}

	provider := findIstioExtensionProvider(mesh, gatewayExtAuthzProviderName)
	if provider == nil {
		t.Fatalf("Istio meshConfig is missing %s extension provider", gatewayExtAuthzProviderName)
	}
	if provider.EnvoyExtAuthzGRPC == nil {
		t.Fatalf("Istio meshConfig provider %s is not an envoyExtAuthzGrpc provider", gatewayExtAuthzProviderName)
	}

	grpc := provider.EnvoyExtAuthzGRPC
	assertEqual(t, "ext-authz service", grpc.Service, "gateway-ext-authz.istio-ingress.svc.cluster.local")
	assertEqual(t, "ext-authz port", grpc.Port, 3001)
	assertEqual(t, "ext-authz timeout", grpc.Timeout, "1s")
	assertStringSet(t, "ext-authz check request headers", grpc.IncludeRequestHeadersInCheck, []string{
		"authorization",
		"cookie",
		"x-request-id",
		"x-b3-traceid",
		"x-b3-spanid",
		"x-b3-parentspanid",
		"x-b3-sampled",
		"x-b3-flags",
		"b3",
		"traceparent",
		"tracestate",
	})
	assertStringSet(t, "ext-authz allow upstream headers", grpc.HeadersToUpstreamOnAllow, []string{"authorization"})
	assertStringSet(t, "ext-authz deny downstream headers", grpc.HeadersToDownstreamOnDeny, []string{"www-authenticate"})

	assertStringContains(t, "proxyStatsMatcher inclusionRegexps", mesh.DefaultConfig.ProxyStatsMatcher.InclusionRegexps, ".*ext_authz.*")
	assertStringContains(t, "proxyStatsMatcher inclusionRegexps", mesh.DefaultConfig.ProxyStatsMatcher.InclusionRegexps, "cluster\\.outbound\\|3001\\|\\|gateway-ext-authz\\.istio-ingress\\.svc\\.cluster\\.local;.*")

	assertKubernetesObjectAbsent(t, "service", "gateway-ext-authz", "istio-ingress")
}

func requireIstioMeshConfig(t *testing.T) istioMeshConfig {
	t.Helper()

	cm := kubectlJSON[configMap](t, "get", "configmap", "istio", "-n", "istio-system")
	meshYAML := cm.Data["mesh"]
	if meshYAML == "" {
		t.Fatal("istio-system/configmap/istio is missing data key mesh")
	}

	var mesh istioMeshConfig
	if err := yaml.Unmarshal([]byte(meshYAML), &mesh); err != nil {
		t.Fatalf("failed to parse istio mesh config: %v\nmesh:\n%s", err, meshYAML)
	}
	return mesh
}

func findIstioExtensionProvider(mesh istioMeshConfig, name string) *istioExtensionProvider {
	for i := range mesh.ExtensionProviders {
		if mesh.ExtensionProviders[i].Name == name {
			return &mesh.ExtensionProviders[i]
		}
	}
	return nil
}

func assertKubernetesObjectAbsent(t *testing.T, kind, name, namespace string) {
	t.Helper()

	args := []string{"get", kind, name}
	if namespace != "" {
		args = append(args, "-n", namespace)
	}
	args = append(args, "-o", "name")
	output, err := runCommandE(defaultCommandTimeout, "kubectl", args...)
	if err == nil {
		t.Fatalf("expected %s to be absent, but it exists: %s", describeObject(namespace, kind, name), strings.TrimSpace(output))
	}
	if !strings.Contains(err.Error(), "NotFound") && !strings.Contains(err.Error(), "not found") {
		t.Fatalf("failed to check whether %s is absent: %v", describeObject(namespace, kind, name), err)
	}
}

func assertServiceMonitorInstalled(t *testing.T, namespace, name string) {
	t.Helper()

	output, err := runCommandE(defaultCommandTimeout, "kubectl", "get", "servicemonitor", name, "-n", namespace, "-o", "name")
	if err != nil {
		t.Fatalf("ServiceMonitor %s/%s is not installed: %v", namespace, name, err)
	}
	got := strings.TrimSpace(output)
	if got != "servicemonitor.monitoring.coreos.com/"+name && got != "servicemonitor/"+name {
		t.Fatalf("unexpected ServiceMonitor name for %s/%s: %s", namespace, name, got)
	}
}

func assertPodMonitorInstalled(t *testing.T, namespace, name string) {
	t.Helper()

	output, err := runCommandE(defaultCommandTimeout, "kubectl", "get", "podmonitor", name, "-n", namespace, "-o", "name")
	if err != nil {
		t.Fatalf("PodMonitor %s/%s is not installed: %v", namespace, name, err)
	}
	got := strings.TrimSpace(output)
	if got != "podmonitor.monitoring.coreos.com/"+name && got != "podmonitor/"+name {
		t.Fatalf("unexpected PodMonitor name for %s/%s: %s", namespace, name, got)
	}
}

func assertPrometheusRemoteWriteReceiverEnabled(t *testing.T, namespace, name string) {
	t.Helper()

	output, err := runCommandE(defaultCommandTimeout, "kubectl", "get", "prometheus", name, "-n", namespace, "-o", "jsonpath={.spec.enableRemoteWriteReceiver}")
	if err != nil {
		t.Fatalf("Prometheus %s/%s is not installed or does not expose remote write receiver status: %v", namespace, name, err)
	}
	if strings.TrimSpace(output) != "true" {
		t.Fatalf("Prometheus %s/%s remote write receiver is not enabled: %q", namespace, name, output)
	}
}

func assertEqual[T comparable](t *testing.T, name string, actual, expected T) {
	t.Helper()
	if actual != expected {
		t.Fatalf("%s is %v, expected %v", name, actual, expected)
	}
}

func assertStringContains(t *testing.T, name string, actual []string, expected string) {
	t.Helper()
	for _, value := range actual {
		if value == expected {
			return
		}
	}
	t.Fatalf("%s does not contain %q; got %v", name, expected, actual)
}

func assertStringSet(t *testing.T, name string, actual, expected []string) {
	t.Helper()
	var failures []string
	for _, value := range expected {
		if !stringSliceContains(actual, value) {
			failures = append(failures, fmt.Sprintf("missing %q", value))
		}
	}
	for _, value := range actual {
		if !stringSliceContains(expected, value) {
			failures = append(failures, fmt.Sprintf("unexpected %q", value))
		}
	}
	failWithList(t, name+" mismatch", failures)
}

func stringSliceContains(values []string, expected string) bool {
	for _, value := range values {
		if value == expected {
			return true
		}
	}
	return false
}

func requireServiceLoadBalancerIP(t *testing.T, namespace, name string) string {
	t.Helper()

	svc := kubectlJSON[service](t, "get", "service", name, "-n", namespace)
	address := loadBalancerAddress(svc)
	if address == "" {
		t.Fatalf("%s has no LoadBalancer ingress", describeObject(namespace, "service", name))
	}
	if !strings.Contains(address, ".") {
		t.Fatalf("%s LoadBalancer ingress is not an IPv4 address: %s", describeObject(namespace, "service", name), address)
	}
	return address
}

func assertCertManagerResourcesReady(t *testing.T) {
	t.Helper()

	var failures []string
	for _, cert := range kubectlJSON[certificateList](t, "get", "certificates.cert-manager.io", "-A").Items {
		if !resourceReady(cert.Status.Conditions) {
			failures = append(failures, fmt.Sprintf("%s is not Ready", describeObject(cert.Metadata.Namespace, "certificate", cert.Metadata.Name)))
		}
	}
	for _, issuer := range kubectlJSON[issuerList](t, "get", "issuers.cert-manager.io", "-A").Items {
		if !resourceReady(issuer.Status.Conditions) {
			failures = append(failures, fmt.Sprintf("%s is not Ready", describeObject(issuer.Metadata.Namespace, "issuer", issuer.Metadata.Name)))
		}
	}
	for _, issuer := range kubectlJSON[issuerList](t, "get", "clusterissuers.cert-manager.io").Items {
		if !resourceReady(issuer.Status.Conditions) {
			failures = append(failures, fmt.Sprintf("%s is not Ready", describeObject("", "clusterissuer", issuer.Metadata.Name)))
		}
	}

	failWithList(t, "cert-manager resources are not ready", failures)
}

func rootCAFingerprint(t *testing.T) string {
	t.Helper()

	cert := rootCACertificate(t)
	sum := sha256.Sum256(cert.Raw)
	return strings.ToUpper(hex.EncodeToString(sum[:]))
}

func rootCACertificate(t *testing.T) *x509.Certificate {
	t.Helper()

	pemBytes := rootCAPEM(t)
	block, _ := pem.Decode(pemBytes)
	if block == nil {
		t.Fatal("root CA certificate data does not contain a PEM block")
	}
	cert, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		t.Fatalf("failed to parse root CA certificate: %v", err)
	}
	return cert
}

func rootCAPEM(t *testing.T) []byte {
	t.Helper()

	secret := kubectlJSON[secret](t, "get", "secret", rootCASecret, "-n", "cert-manager")
	encoded := secret.Data["tls.crt"]
	if encoded == "" {
		t.Fatalf("secret cert-manager/%s is missing data key tls.crt", rootCASecret)
	}

	pemBytes, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil {
		t.Fatalf("failed to base64-decode root CA certificate: %v", err)
	}
	return pemBytes
}

func desiredReplicas(replicas *int) int {
	if replicas == nil {
		return 1
	}
	return *replicas
}

func namespaceChecked(namespace string, namespaces []string) bool {
	for _, checked := range namespaces {
		if namespace == checked {
			return true
		}
	}
	return false
}

func podReady(item pod) bool {
	for _, condition := range item.Status.Conditions {
		if condition.Type == "Ready" && condition.Status == "True" {
			return true
		}
	}
	return false
}

func isBadWaitingReason(reason string) bool {
	switch reason {
	case "CrashLoopBackOff", "CreateContainerConfigError", "CreateContainerError", "ErrImagePull", "ImagePullBackOff", "InvalidImageName", "RunContainerError":
		return true
	default:
		return false
	}
}

func endpointReady(endpoint endpoint) bool {
	return endpoint.Conditions.Ready == nil || *endpoint.Conditions.Ready
}

func serviceKey(namespace, name string) string {
	return namespace + "/" + name
}

func loadBalancerAddress(svc service) string {
	if len(svc.Status.LoadBalancer.Ingress) == 0 {
		return ""
	}
	if svc.Status.LoadBalancer.Ingress[0].IP != "" {
		return svc.Status.LoadBalancer.Ingress[0].IP
	}
	return svc.Status.LoadBalancer.Ingress[0].Hostname
}

func resourceReady(conditions []condition) bool {
	for _, condition := range conditions {
		if condition.Type == "Ready" && condition.Status == "True" {
			return true
		}
	}
	return false
}
