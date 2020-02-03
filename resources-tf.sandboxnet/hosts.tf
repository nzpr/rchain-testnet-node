resource "google_compute_address" "node_ext_addr" {
  count        = var.node_count
  name         = "${var.resources_name}-node${count.index}"
  address_type = "EXTERNAL"
}

resource "google_dns_record_set" "node_dns_record" {
  count        = var.node_count
  name         = "node${count.index}${var.dns_suffix}."
  managed_zone = "rchain-dev"
  type         = "A"
  ttl          = 3600
  rrdatas      = [google_compute_address.node_ext_addr[count.index].address]
}

resource "google_compute_instance" "node_host" {
  count        = var.node_count
  name         = "${var.resources_name}-node${count.index}"
  hostname     = "node${count.index}${var.dns_suffix}"
  machine_type = "n1-standard-4"
  enable_display = "false"
  labels = {"label"="this_is_to_make_terraform_happy"}
  metadata = {"metadata"="this_is_to_make_terraform_happy"}

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-1804-lts"
      size  = 160
      type  = "pd-standard"
    }
  }

  tags = [
    "${var.resources_name}-node",
    "collectd-out",
    "elasticsearch-out",
    "logstash-tcp-out",
    "logspout-http",
  ]

  service_account {
    email  = google_service_account.svc_account_node.email
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  network_interface {
    network = data.google_compute_network.default_network.self_link
    access_config {
      nat_ip = google_compute_address.node_ext_addr[count.index].address
      //public_ptr_domain_name = "node${count.index}${var.dns_suffix}."
    }
  }

  depends_on = [google_dns_record_set.node_dns_record]

  connection {
    type        = "ssh"
    host        = self.network_interface[0].access_config[0].nat_ip
    user        = "root"
    private_key = file("~/.ssh/google_compute_engine")
  }

  provisioner "file" {
    source      = var.rchain_sre_git_crypt_key_file
    destination = "/root/rchain-sre-git-crypt-key"
  }

  provisioner "remote-exec" {
    script = "../bootstrap.sandboxnet"
  }

  scheduling {
    preemptible       = false
    automatic_restart = true
  }
}

