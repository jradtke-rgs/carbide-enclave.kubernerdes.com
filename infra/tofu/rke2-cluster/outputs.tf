output "vm_names" {
  description = "Names of provisioned RKE2 VMs"
  value       = [for vm in harvester_virtualmachine.rke2 : vm.name]
}

output "vm_ips" {
  description = "IP addresses assigned to RKE2 VMs"
  value = {
    for name, vm in harvester_virtualmachine.rke2 :
    name => try(vm.network_interface[0].ip_address, "pending")
  }
}
