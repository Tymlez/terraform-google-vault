locals {
  vault_config = jsonencode(
    {
      "storage" = {
        "gcs" = {
          "bucket"     = local.vault_storage_bucket_name
          "ha_enabled" = "false"
        }
      },
      "seal" = {
        "gcpckms" = {
          "project"    = var.project,
          "region"     = var.location,
          "key_ring"   = local.vault_kms_keyring_name,
          "crypto_key" = google_kms_crypto_key.vault.name
        }
      },
      "default_lease_ttl" = "168h",
      "max_lease_ttl"     = "720h",
      "disable_mlock"     = "true",
      "listener" = {
        "tcp" = {
          "address"     = "0.0.0.0:8080",
          "tls_disable" = "1"
        }
      },
      "ui" = var.vault_ui
    }
  )
  vault_kms_keyring_name    = var.vault_kms_keyring_name != "" ? var.vault_kms_keyring_name : "${var.name}-${lower(random_id.vault.hex)}-kr"
  vault_storage_bucket_name = var.vault_storage_bucket_name != "" ? var.vault_storage_bucket_name : "${var.name}-${lower(random_id.vault.hex)}-bucket"
}

resource "random_id" "vault" {
  byte_length = 2
}

resource "google_service_account" "vault" {
  project      = var.project
  account_id   = var.vault_service_account_id
  display_name = "Vault Service Account for KMS auto-unseal"
}

resource "google_storage_bucket" "vault" {
  name          = local.vault_storage_bucket_name
  project       = var.project
  location      = var.vault_storage_bucket_location
  force_destroy = var.bucket_force_destroy
}

resource "google_storage_bucket_iam_member" "member" {
  bucket = google_storage_bucket.vault.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.vault.email}"
}

# Create a KMS key ring
resource "google_kms_key_ring" "vault" {
  name     = local.vault_kms_keyring_name
  project  = var.project
  location = var.location
}

# Create a crypto key for the key ring, rotate daily
resource "google_kms_crypto_key" "vault" {
  name            = "${var.name}-key"
  key_ring        = google_kms_key_ring.vault.id
  rotation_period = var.vault_kms_key_rotation

  version_template {
    algorithm        = var.vault_kms_key_algorithm
    protection_level = var.vault_kms_key_protection_level
  }
}

# Add the service account to the Keyring
resource "google_kms_key_ring_iam_member" "vault" {
  key_ring_id = google_kms_key_ring.vault.id
  role        = "roles/owner"
  member      = "serviceAccount:${google_service_account.vault.email}"
}

resource "google_cloud_run_service" "vault" {
  for_each                   = toset(var.run_regions)
  name                       = "${var.name}-${each.key}"
  project                    = var.project
  location                   = each.key
  provider = google-beta
  autogenerate_revision_name = true

  metadata {
    annotations = {
#      "autoscaling.knative.dev/maxScale" = 1 # HA not Supported
      "run.googleapis.com/vpc-access-connector" = var.vpc_connector != "" ? var.vpc_connector : null
      "run.googleapis.com/ingress" = "internal-and-cloud-load-balancing" #set for load balancer too
    }
  }
  template {
    spec {
      service_account_name  = google_service_account.vault.email
      container_concurrency = var.container_concurrency
      containers {
        # Specifying args seems to require the command / entrypoint
        image   = var.vault_image
        command = ["/usr/local/bin/docker-entrypoint.sh"]
        args    = ["server"]

        env {
          name  = "SKIP_SETCAP"
          value = "true"
        }

        env {
          name  = "VAULT_LOCAL_CONFIG"
          value = local.vault_config
        }

        env {
          name  = "VAULT_API_ADDR"
          value = var.vault_api_addr
        }
        resources {
          limits = {
            "cpu"    = "1000m"
            "memory" = "256Mi"
          }
          requests = {}
        }
      }
    }
    metadata {
      annotations = {
        "autoscaling.knative.dev/maxScale" = 1 # Disable multiple per region for now
      }
    }
  }
}

resource "google_compute_region_network_endpoint_group" "serverless_neg" {
  for_each = toset(var.run_regions)

  name                  = "${var.stage}-${var.app_name}-vault-serverless-neg"
  network_endpoint_type = "SERVERLESS"
  region                = each.key

  cloud_run {
    service = google_cloud_run_service.vault[each.key].name
  }
}

data "google_iam_policy" "noauth" {
  binding {
    role = "roles/run.invoker"
    members = [
      "allUsers",
    ]
  }
}

resource "google_cloud_run_service_iam_policy" "noauth" {
  for_each = toset(var.run_regions)
  location = google_cloud_run_service.vault[each.key].location
  project  = google_cloud_run_service.vault[each.key].project
  service  = google_cloud_run_service.vault[each.key].name

  policy_data = data.google_iam_policy.noauth.policy_data
}

output "app_name" {
  value = values(google_cloud_run_service.vault)[*].name
}

output "app_url" {
  value = values(google_cloud_run_service.vault)[*].status[0].url
}

output "service_account_email" {
  value = google_service_account.vault[*].email
}
