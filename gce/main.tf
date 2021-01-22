provider "google" {
  project = var.project
  zone = var.zone
}

provider "google-beta" {
  project = var.project
  zone = var.zone
}

terraform {
  required_version = ">= 0.12"
  backend "gcs" {
    bucket = "rchain-terraform-state"
    prefix = "shard"
  }
}

data "google_compute_network" "shard-network" {
  name = "default"
}

data "google_compute_subnetwork" "region-subnetwork" {
  name = var.tag
  network = google_compute_network.shard-network.self_link
  region = var.region
  ip_cidr_range = var.subnet
}

resource "google_compute_firewall" "fw_public_node" {
  name = "${var.tag}-node-public"
  network = google_compute_network.shard-network.self_link
  priority = 530
  target_tags = ["${var.tag}-node"]
  allow {
    protocol = "tcp"
    ports = [22, 40403, 18080]
  }
}

resource "google_compute_firewall" "fw_public_node_rpc" {
  name = "${var.tag}-node-rpc"
  network = google_compute_network.shard-network.self_link
  priority = 540
  target_tags = ["${var.tag}-node"]
  allow {
    protocol = "tcp"
    ports = [40401]
  }
}

resource "google_compute_firewall" "fw_node_p2p" {
  name = "${var.tag}-node-p2p"
  network = google_compute_network.shard-network.self_link
  priority = 550
  source_ranges = ["0.0.0.0/0"]
  target_tags = ["${var.tag}-node"]
  allow {
    protocol = "tcp"
    ports = [40400, 40404]
  }
}

resource "google_compute_firewall" "fw_node_deny" {
  name = "${var.tag}-node-deny"
  network = google_compute_network.shard-network.self_link
  priority = 5010
  target_tags = ["${var.tag}-node"]
  deny {
    protocol = "tcp"
  }
  deny {
    protocol = "udp"
  }
}

resource "google_compute_address" "node_ext_addr" {
  count = var.node_count
  name = "${var.tag}-node${count.index}-ext"
  address_type = "EXTERNAL"
}

resource google_compute_address "node_int_addr" {
  count = var.node_count
  name = "${var.tag}-node${count.index}-int"
  address_type = "INTERNAL"
  subnetwork = google_compute_network.region-subnetwork.self_link
  address = cidrhost(google_compute_subnetwork.region-subnetwork.ip_cidr_range, count.index + 10)
}

resource "google_dns_record_set" "node_dns_record" {
  count = var.node_count
  name = "node${count.index}.${var.domain}."
  managed_zone = "dev"
  type = "A"
  ttl = 3600
  rrdatas = [google_compute_address.node_ext_addr[count.index].address]
}

data google_compute_address "node_addr_ext" {
  count = var.node_count
  name = "${var.tag}-node${count.index}-ext"
}

data google_compute_address "node_addr_int" {
  count = var.node_count
  name = "${var.tag}-node${count.index}-int"
}

resource "google_compute_instance" "node_host" {
  count = var.node_count
  name = "${var.tag}-node${count.index}"
  hostname = "node${count.index}${var.domain}"
  machine_type = var.machine_type

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-1804-lts"
      size = 100
      type = "pd-ssd"
    }
  }

  tags = [
    "${var.tag}-node",
    "collectd-out",
    "elasticsearch-out",
    "logstash-tcp-out",
    "logspout-http",
  ]

  network_interface {
    subnetwork = data.google_compute_subnetwork.subnetwork.self_link
    network_ip = data.google_compute_address.node_addr_int[count.index].address
    access_config {
      nat_ip = data.google_compute_address.node_addr_ext[count.index].address
    }
  }

  connection {
    type = "ssh"
    host = self.network_interface[0].access_config[0].nat_ip
    user = "root"
    private_key = file("~/.ssh/google_compute_engine")
  }

  provisioner "file" {
    source = var.gitcrypt_key_file
    destination = "/root/rshard-git-crypt-secret.key"
  }

  provisioner "file" {
    source = "../genesis_bonds.txt"
    destination = "/root/bonds.txt"
  }

  provisioner "file" {
    source = "../genesis_wallets.txt"
    destination = "/root/wallets.txt"
  }

  provisioner "remote-exec" {
    script = "../bootstrap.sh"
  }
}
