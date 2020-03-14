variable "resources_name" { default = "sandboxnet" }
variable "gcp_zone" { default = "us-west1-b" }
variable "node_count" { default = 5 }
variable "dns_suffix" { default = ".sandboxnet.rchain-dev.tk" }
variable "rchain_sre_git_crypt_key_file" {}

provider "google" {
  project = "developer-222401"
  zone    = var.gcp_zone
}

provider "google-beta" {
  project = "developer-222401"
  zone    = var.gcp_zone
}

terraform {
  required_version = ">= 0.12"
  backend "gcs" {
    bucket = "rchain-terraform-state"
    prefix = "sandboxnet"
  }
}
