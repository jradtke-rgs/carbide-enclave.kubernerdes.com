terraform {
  required_providers {
    harvester = {
      source  = "harvester/harvester"
      version = "~> 0.6"
    }
  }
}

provider "harvester" {
  kubeconfig = var.kubeconfig
}

locals {
  nodes = {
    rancher-01 = { ip = "${var.ip_prefix}.31", mac = "52:54:00:01:00:01" }
    rancher-02 = { ip = "${var.ip_prefix}.32", mac = "52:54:00:01:00:02" }
    rancher-03 = { ip = "${var.ip_prefix}.33", mac = "52:54:00:01:00:03" }
  }
}

# ── SSH keypair ───────────────────────────────────────────────────────────────

resource "harvester_ssh_key" "rke2" {
  name      = "rke2-enclave"
  namespace = var.namespace
  public_key = var.ssh_public_key
}

# ── Cloud-init user-data (common to all nodes) ────────────────────────────────

resource "harvester_cloudinit_secret" "rke2" {
  name      = "rke2-cloudinit"
  namespace = var.namespace

  user_data = templatefile("${path.module}/templates/user-data.yaml.tpl", {
    ssh_public_key = var.ssh_public_key
    admin_user     = var.admin_user
  })
}

# ── VMs ───────────────────────────────────────────────────────────────────────

resource "harvester_virtualmachine" "rke2" {
  for_each = local.nodes

  name                 = each.key
  namespace            = var.namespace
  restart_after_update = true

  tags = {
    "part-of"    = "carbide-enclave"
    "managed-by" = "opentofu"
    "role"       = "rke2-server"
  }

  cpu    = var.vm_cpu
  memory = var.vm_memory

  efi         = true
  secure_boot = false

  run_strategy = "RerunOnFailure"
  hostname     = each.key
  machine_type = "q35"

  network_interface {
    name           = "eth0"
    network_name   = var.network_name
    type           = "bridge"
    mac_address    = each.value.mac
    wait_for_lease = true
  }

  disk {
    name        = "rootdisk"
    type        = "disk"
    size        = var.vm_disk_size
    bus         = "virtio"
    boot_order  = 1
    image       = data.harvester_image.sl_micro.id
    auto_delete = true
  }

  cloudinit {
    user_data_secret_name = harvester_cloudinit_secret.rke2.name
    type                  = "noCloud"
  }
}

# ── Data sources ──────────────────────────────────────────────────────────────

data "harvester_image" "sl_micro" {
  name      = "sl-micro-6-2-base"
  namespace = "default"
}
