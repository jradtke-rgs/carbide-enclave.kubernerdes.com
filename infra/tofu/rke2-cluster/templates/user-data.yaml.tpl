#cloud-config
users:
  - name: ${admin_user}
    groups: [wheel, sudo]
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - ${ssh_public_key}

# Disable password auth — SSH key only
ssh_pwauth: false

# NTP — point at bastion (airgap)
ntp:
  enabled: true
  servers:
    - 10.0.0.10

# DNS search domain
manage_resolv_conf: true
resolv_conf:
  nameservers:
    - 10.0.0.10
  searchdomains:
    - carbide-enclave.kubernerdes.com

runcmd:
  # SL-Micro: grow root partition to fill disk
  - growpart /dev/vda 3 || true
  - resize2fs /dev/vda3 || btrfs filesystem resize max / || true
