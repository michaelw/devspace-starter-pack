resource "random_id" "project_suffix" {
  byte_length = 3
}

check "project_parent" {
  assert {
    condition     = var.org_id != "" || var.folder_id != ""
    error_message = "Set org_id or folder_id."
  }
}

resource "google_project" "ephemeral" {
  name                = var.project_name
  project_id          = local.project_id
  billing_account     = var.billing_account_id
  org_id              = local.parent_is_folder ? null : var.org_id
  folder_id           = local.parent_is_folder ? var.folder_id : null
  auto_create_network = true
  deletion_policy     = "DELETE"
  labels              = var.labels
}

locals {
  project_services = toset([
    "cloudbilling.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "compute.googleapis.com",
    "container.googleapis.com",
    "dns.googleapis.com",
    "artifactregistry.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "iap.googleapis.com",
    "networksecurity.googleapis.com",
    "networkservices.googleapis.com",
    "serviceusage.googleapis.com",
  ])
}

resource "google_project_service" "enabled" {
  for_each = local.project_services

  project            = google_project.ephemeral.project_id
  service            = each.value
  disable_on_destroy = false
}

resource "google_service_account" "terraform" {
  project      = google_project.ephemeral.project_id
  account_id   = "terraform-runner"
  display_name = "Terraform runner for ephemeral DevSpace GKE"

  depends_on = [google_project_service.enabled]
}

resource "google_project_iam_member" "terraform_project_admin" {
  for_each = local.terraform_project_admin_roles

  project = google_project.ephemeral.project_id
  role    = each.value
  member  = google_service_account.terraform.member
}

resource "google_service_account" "config_connector" {
  count = var.config_connector_enabled ? 1 : 0

  project      = google_project.ephemeral.project_id
  account_id   = "config-connector"
  display_name = "Config Connector controller for ephemeral DevSpace GKE"

  depends_on = [google_project_service.enabled]
}

resource "google_project_iam_member" "config_connector_project_admin" {
  for_each = var.config_connector_enabled ? toset(var.config_connector_iam_roles) : toset([])

  project = google_project.ephemeral.project_id
  role    = each.value
  member  = google_service_account.config_connector[0].member
}

resource "google_artifact_registry_repository" "dev" {
  project       = google_project.ephemeral.project_id
  location      = var.region
  repository_id = var.dev_registry_repository_id
  description   = "Ephemeral DevSpace Starter Pack developer/test Docker images."
  format        = "DOCKER"
  labels        = var.labels

  depends_on = [google_project_service.enabled]
}

resource "google_artifact_registry_repository_iam_member" "dev_registry_writer" {
  for_each = toset(var.dev_registry_writer_members)

  project    = google_project.ephemeral.project_id
  location   = google_artifact_registry_repository.dev.location
  repository = google_artifact_registry_repository.dev.name
  role       = "roles/artifactregistry.writer"
  member     = each.value
}

resource "google_artifact_registry_repository_iam_member" "dev_registry_node_reader" {
  project    = google_project.ephemeral.project_id
  location   = google_artifact_registry_repository.dev.location
  repository = google_artifact_registry_repository.dev.name
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${local.gke_node_service_account_email}"
}

resource "google_iap_web_iam_member" "iap_accessor" {
  for_each = toset(var.iap_accessor_members)

  project = google_project.ephemeral.project_id
  role    = "roles/iap.httpsResourceAccessor"
  member  = each.value

  depends_on = [google_project_service.enabled]
}

resource "google_compute_network" "main" {
  project                 = google_project.ephemeral.project_id
  name                    = "devspace-gke"
  auto_create_subnetworks = false

  depends_on = [google_project_service.enabled]
}

resource "google_compute_subnetwork" "main" {
  project       = google_project.ephemeral.project_id
  name          = "devspace-gke"
  region        = var.region
  network       = google_compute_network.main.id
  ip_cidr_range = "10.40.0.0/20"

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = "10.44.0.0/14"
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = "10.48.0.0/20"
  }
}

resource "google_compute_subnetwork" "proxy_only" {
  project       = google_project.ephemeral.project_id
  name          = "devspace-gke-proxy-only"
  region        = var.region
  network       = google_compute_network.main.id
  ip_cidr_range = "10.49.0.0/23"
  purpose       = "REGIONAL_MANAGED_PROXY"
  role          = "ACTIVE"
}

resource "google_container_cluster" "main" {
  project             = google_project.ephemeral.project_id
  name                = var.cluster_name
  location            = var.region
  enable_autopilot    = true
  deletion_protection = false
  network             = google_compute_network.main.id
  subnetwork          = google_compute_subnetwork.main.id
  networking_mode     = "VPC_NATIVE"

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  workload_identity_config {
    workload_pool = "${google_project.ephemeral.project_id}.svc.id.goog"
  }

  gateway_api_config {
    channel = "CHANNEL_STANDARD"
  }

  resource_labels = var.labels

  depends_on = [google_project_service.enabled]
}

resource "google_dns_managed_zone" "gcp_kube" {
  project       = google_project.ephemeral.project_id
  name          = var.dns_zone_name
  dns_name      = var.dns_domain
  description   = "Ephemeral DevSpace Starter Pack split-DNS zone."
  force_destroy = true
  labels        = var.labels

  depends_on = [google_project_service.enabled]
}

resource "google_service_account" "external_dns" {
  project      = google_project.ephemeral.project_id
  account_id   = "external-dns"
  display_name = "external-dns for ephemeral DevSpace GKE"

  depends_on = [google_project_service.enabled]
}

resource "google_project_iam_custom_role" "external_dns_zone_writer" {
  project     = google_project.ephemeral.project_id
  role_id     = "externalDnsZoneWriter"
  title       = "External DNS Zone Writer"
  description = "Minimal Cloud DNS permissions for external-dns in the ephemeral project."
  permissions = [
    "dns.changes.create",
    "dns.changes.get",
    "dns.changes.list",
    "dns.managedZones.get",
    "dns.managedZones.list",
    "dns.projects.get",
    "dns.resourceRecordSets.create",
    "dns.resourceRecordSets.delete",
    "dns.resourceRecordSets.list",
    "dns.resourceRecordSets.update",
  ]
}

resource "google_project_iam_member" "external_dns_zone_writer" {
  project = google_project.ephemeral.project_id
  role    = google_project_iam_custom_role.external_dns_zone_writer.name
  member  = google_service_account.external_dns.member
}

resource "google_service_account_iam_member" "external_dns_workload_identity" {
  service_account_id = google_service_account.external_dns.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${google_project.ephemeral.project_id}.svc.id.goog[external-dns/external-dns]"

  depends_on = [google_container_cluster.main]
}

resource "google_service_account_iam_member" "config_connector_workload_identity" {
  count = var.config_connector_enabled ? 1 : 0

  service_account_id = google_service_account.config_connector[0].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${google_project.ephemeral.project_id}.svc.id.goog[cnrm-system/cnrm-controller-manager]"

  depends_on = [google_container_cluster.main]
}
