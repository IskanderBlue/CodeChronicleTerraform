variable "project_id" {
  type = string
}

variable "region" {
  type    = string
  default = "us-central1"
}

variable "zone" {
  type    = string
  default = "us-central1-a"
}

# A pinned image, not the cos-stable family.  Terraform resolves a family once,
# at create time, and never sees a newer image in it, so the VM stayed on
# kernel 6.6.113 for months.  A pinned name makes an upgrade a one-line diff
# that plans as a replacement.  Auto-update is off on this VM: a reboot does
# not change the kernel.
#
# cos-stable-121-18867-652-12 carries kernel COS-6.6.159, the first 6.6 kernel
# with the fix for CVE-2026-98432 (TCP handshake use-after-free, CVSS 9.8).
# List newer images with:
#   gcloud compute images describe-from-family cos-stable --project cos-cloud
variable "boot_image" {
  type    = string
  default = "projects/cos-cloud/global/images/cos-stable-121-18867-652-12"
}

variable "machine_type" {
  type    = string
  default = "e2-micro"
}

variable "network_name" {
  type = string
}

variable "subnet_name" {
  type = string
}

variable "secret_names" {
  type = map(string)
}

variable "app_image" {
  type    = string
  default = ""
}

variable "domain" {
  type = string
}

variable "subdomains" {
  type        = list(string)
  default     = ["app", "www"]
  description = "Host subdomains the app serves on; folded into Django ALLOWED_HOSTS."
}
