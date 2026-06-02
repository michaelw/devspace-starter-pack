variable "billing_account_id" {
  description = "Billing account ID to link to the ephemeral project."
  type        = string
}

variable "org_id" {
  description = "Organization ID for the ephemeral project. Ignored when folder_id is set."
  type        = string
  default     = ""
}

variable "folder_id" {
  description = "Folder ID for the ephemeral project. Takes precedence over org_id when set."
  type        = string
  default     = ""
}

variable "project_id" {
  description = "Optional explicit project ID. Defaults to devspace-gke-<random>."
  type        = string
  default     = ""
}

variable "project_name" {
  description = "Display name for the ephemeral project."
  type        = string
  default     = "devspace-starter-pack-gke"
}

variable "region" {
  description = "GCP region for regional resources."
  type        = string
  default     = "us-central1"
}

variable "cluster_name" {
  description = "GKE cluster name."
  type        = string
  default     = "devspace-starter-pack"
}

variable "dns_domain" {
  description = "Cloud DNS zone DNS name. Keep the trailing dot."
  type        = string
  default     = "gcp.kube."
}

variable "dns_zone_name" {
  description = "Cloud DNS managed zone name."
  type        = string
  default     = "gcp-kube"
}

variable "dev_registry_repository_id" {
  description = "Artifact Registry Docker repository ID for local developer/test images."
  type        = string
  default     = "devspace-dev"
}

variable "dev_registry_writer_members" {
  description = "IAM members granted roles/artifactregistry.writer on the dev image repository."
  type        = list(string)
  default     = []
}

variable "iap_accessor_members" {
  description = "IAM members granted roles/iap.httpsResourceAccessor for IAP-protected web backends in the ephemeral project."
  type        = list(string)
  default     = []
}

variable "config_connector_iam_roles" {
  description = "Project IAM roles granted to the cluster-mode Config Connector controller in the ephemeral project."
  type        = list(string)
  default = [
    "roles/artifactregistry.admin",
    "roles/compute.networkAdmin",
    "roles/compute.loadBalancerAdmin",
    "roles/container.admin",
    "roles/dns.admin",
    "roles/iam.serviceAccountAdmin",
    "roles/iam.serviceAccountUser",
    "roles/iap.admin",
    "roles/networkservices.serviceExtensionsAdmin",
    "roles/resourcemanager.projectIamAdmin",
    "roles/serviceusage.serviceUsageAdmin",
  ]
}

variable "config_connector_enabled" {
  description = "Whether to create the project-scoped Config Connector controller identity and Workload Identity binding."
  type        = bool
  default     = false
}

variable "labels" {
  description = "Labels applied to supported GCP resources."
  type        = map(string)
  default = {
    app       = "devspace-starter-pack"
    lifecycle = "ephemeral"
  }
}

locals {
  generated_project_id           = "devspace-gke-${random_id.project_suffix.hex}"
  project_id                     = var.project_id != "" ? var.project_id : local.generated_project_id
  parent_is_folder               = var.folder_id != ""
  dev_registry_host              = "${var.region}-docker.pkg.dev"
  dev_registry                   = "${local.dev_registry_host}/${google_project.ephemeral.project_id}/${var.dev_registry_repository_id}"
  gke_node_service_account_email = "${google_project.ephemeral.number}-compute@developer.gserviceaccount.com"
  terraform_project_admin_roles = toset([
    "roles/artifactregistry.admin",
    "roles/compute.networkAdmin",
    "roles/compute.loadBalancerAdmin",
    "roles/container.admin",
    "roles/dns.admin",
    "roles/iam.serviceAccountAdmin",
    "roles/iam.serviceAccountUser",
    "roles/iap.admin",
    "roles/networkservices.serviceExtensionsAdmin",
    "roles/resourcemanager.projectIamAdmin",
    "roles/serviceusage.serviceUsageAdmin",
  ])
}
