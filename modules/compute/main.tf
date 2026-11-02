locals {
  # apex + every subdomain + localhost, e.g. "codechronicle.ca,app.codechronicle.ca,www.codechronicle.ca,localhost"
  allowed_hosts = join(",", concat(
    [var.domain],
    [for s in var.subdomains : "${s}.${var.domain}"],
    ["localhost"],
  ))
}

resource "google_service_account" "vm" {
  account_id   = "codechroniclenet-vm"
  display_name = "CodeChronicle VM"
  project      = var.project_id
}

resource "google_project_iam_member" "secret_accessor" {
  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.vm.email}"
}

resource "google_project_iam_member" "log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.vm.email}"
}

resource "google_compute_address" "static" {
  name    = "codechroniclenet-ip"
  project = var.project_id
  region  = var.region
}

resource "google_compute_instance" "app" {
  name         = "codechroniclenet-vm"
  project      = var.project_id
  zone         = var.zone
  machine_type = var.machine_type

  tags = ["codechroniclenet-web"]

  boot_disk {
    initialize_params {
      image = var.boot_image
      size  = 30
    }
  }

  network_interface {
    subnetwork = var.subnet_name

    access_config {
      nat_ip = google_compute_address.static.address
    }
  }

  service_account {
    email  = google_service_account.vm.email
    scopes = ["cloud-platform"]
  }

  metadata = {
    enable-oslogin         = "TRUE"
    block-project-ssh-keys = "TRUE"
    startup-script = templatefile("${path.module}/startup.sh", {
      project_id    = var.project_id
      secret_names  = var.secret_names
      app_image     = var.app_image
      allowed_hosts = local.allowed_hosts
      deploy_script = templatefile("${path.module}/deploy-web.sh.tftpl", {
        app_image = var.app_image
      })
    })
  }

  allow_stopping_for_update = true
}
