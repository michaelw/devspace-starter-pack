output "project_id" {
  description = "Ephemeral project ID."
  value       = google_project.ephemeral.project_id
}

output "region" {
  description = "GKE cluster region."
  value       = var.region
}

output "cluster_name" {
  description = "GKE cluster name."
  value       = google_container_cluster.main.name
}

output "dns_domain" {
  description = "Cloud DNS domain."
  value       = google_dns_managed_zone.gcp_kube.dns_name
}

output "dns_zone_name" {
  description = "Cloud DNS managed zone name."
  value       = google_dns_managed_zone.gcp_kube.name
}

output "dns_name_servers" {
  description = "Authoritative Cloud DNS nameservers for split DNS."
  value       = google_dns_managed_zone.gcp_kube.name_servers
}

output "external_dns_service_account_email" {
  description = "Google service account used by external-dns through Workload Identity."
  value       = google_service_account.external_dns.email
}

output "dev_registry_host" {
  description = "Artifact Registry Docker hostname for developer/test images."
  value       = local.dev_registry_host
}

output "dev_registry" {
  description = "Artifact Registry Docker repository path for developer/test images."
  value       = local.dev_registry
}

output "dev_registry_image_prefix" {
  description = "Image prefix app repos should use for GKE developer/test images."
  value       = local.dev_registry
}

output "gke_node_service_account_email" {
  description = "Google service account used by GKE nodes for image pulls."
  value       = local.gke_node_service_account_email
}

output "terraform_service_account_email" {
  description = "Google service account created for follow-up Terraform impersonation."
  value       = google_service_account.terraform.email
}

output "config_connector_service_account_email" {
  description = "Google service account used by Config Connector through Workload Identity."
  value       = try(google_service_account.config_connector[0].email, "")
}

output "get_credentials_args" {
  description = "Arguments for gcloud container clusters get-credentials."
  value = [
    google_container_cluster.main.name,
    "--region",
    var.region,
    "--project",
    google_project.ephemeral.project_id,
  ]
}
