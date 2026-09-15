###############################################################################
# Terraform and Alibaba Cloud provider
###############################################################################

terraform {
  required_version = ">= 1.8.0"

  required_providers {
    alicloud = {
      source = "aliyun/alicloud"

      # Pin a stable 1.x provider instead of accidentally moving to a 2.x beta.
      version = "1.285.0"
    }
  }
}


###############################################################################
# Variables
###############################################################################

# South China 3 (Guangzhou)
variable "region" {
  description = "Alibaba Cloud region"
  type        = string
  default     = "cn-guangzhou"
}

variable "cluster_name" {
  description = "ACK Kubernetes cluster name"
  type        = string
  default     = "k8s-in-action"
}

variable "worker_count" {
  description = "Number of Kubernetes worker nodes"
  type        = number
  default     = 2
}

# This is deliberately small for a learning cluster.
#
# ACK normally restricts instances below 4 vCPU.
# The account must have the low-specification ECS quota enabled.
variable "worker_cpu" {
  description = "vCPU count of each worker"
  type        = number
  default     = 2
}

variable "worker_memory_gib" {
  description = "Memory of each worker in GiB"
  type        = number
  default     = 4
}


###############################################################################
# Provider
###############################################################################

provider "alicloud" {
  region = var.region
}


###############################################################################
# Find a suitable availability zone
###############################################################################

# An Alibaba Cloud region contains one or more availability zones.
#
# We ask Alibaba Cloud which zones currently support:
#   - VSwitch creation
#   - cloud_efficiency disks
#
# This prevents us from hard-coding a Guangzhou zone.
data "alicloud_zones" "available" {
  available_resource_creation = "VSwitch"
  available_disk_category     = "cloud_efficiency"
}



###############################################################################
# VPC
###############################################################################

# VPC = Virtual Private Cloud.
#
# Think of this as our own private virtual network inside Alibaba Cloud.
resource "alicloud_vpc" "lab" {
  vpc_name   = "${var.cluster_name}-vpc"
  cidr_block = "10.0.0.0/16"
}


###############################################################################
# vSwitch
###############################################################################

# A vSwitch is roughly equivalent to a subnet.
#
# Worker nodes will receive private IP addresses from this subnet.
resource "alicloud_vswitch" "lab" {
  vswitch_name = "${var.cluster_name}-vswitch"

  vpc_id  = alicloud_vpc.lab.id
  zone_id = data.alicloud_zones.available.zones[0].id

  cidr_block = "10.0.1.0/24"
}


###############################################################################
# ACK managed Kubernetes cluster
###############################################################################

resource "alicloud_cs_managed_kubernetes" "lab" {
  name = var.cluster_name

  # ack.standard = ACK Managed Basic
  #
  # ACK manages the Kubernetes control plane.
  cluster_spec = "ack.standard"

  # Network where worker nodes live.
  vswitch_ids = [
    alicloud_vswitch.lab.id
  ]

  # Worker nodes do not need their own public IP.
  #
  # This creates a NAT gateway so they can still access the Internet,
  # for example to download container images and packages.
  new_nat_gateway = true

  # Flannel gives Pods their own virtual IP range.
  #
  # These ranges must not overlap the VPC/vSwitch CIDRs.
  pod_cidr = "10.244.0.0/16"

  # ClusterIP Services get addresses from this range.
  service_cidr = "172.20.0.0/16"

  # Create an Internet-accessible endpoint for kube-apiserver,
  # allowing kubectl on your computer to reach the cluster.
  slb_internet_enabled = true

  # Important for a disposable lab.
  deletion_protection = false

  ###########################################################################
  # Kubernetes add-ons
  ###########################################################################

  # Pod network
  addons {
    name   = "flannel"
    config = ""
  }

  # CSI storage support.
  # Useful later when Kubernetes in Action reaches PV/PVC/storage topics.
  addons {
    name   = "csi-plugin"
    config = ""
  }

  addons {
    name   = "csi-provisioner"
    config = ""
  }
}

##################################################
#  Find a suitable worker ECS instance type
##################################################
data "alicloud_instance_types" "worker_2c4g" {
  availability_zone    = data.alicloud_zones.available.zones[0].id
  cpu_core_count       = 2
  memory_size          = 4
  kubernetes_node_role = "Worker"
  instance_charge_type = "PostPaid"
  system_disk_category = "cloud_efficiency"
  is_outdated          = false
}

data "alicloud_instance_types" "worker_4c4g" {
  availability_zone    = data.alicloud_zones.available.zones[0].id
  cpu_core_count       = 4
  memory_size          = 4
  kubernetes_node_role = "Worker"
  instance_charge_type = "PostPaid"
  system_disk_category = "cloud_efficiency"
  is_outdated          = false
}

locals {
  worker_2c4g_types = sort([
    for t in data.alicloud_instance_types.worker_2c4g.instance_types :
    t.id
    if t.id != "ecs.n1.medium"
  ])

  worker_4c4g_types = sort([
    for t in data.alicloud_instance_types.worker_4c4g.instance_types :
    t.id
  ])

  worker_instance_types = concat(
    local.worker_2c4g_types,
    local.worker_4c4g_types
  )
}

###############################################################################
# Kubernetes Worker node pool
###############################################################################

# The ACK control plane is managed separately from worker nodes.
#
# Modern ACK/Terraform practice is:
#
#   ACK cluster
#       +
#   separate node pool
#
# rather than embedding the worker configuration directly in the cluster.
resource "alicloud_cs_kubernetes_node_pool" "workers" {
  cluster_id     = alicloud_cs_managed_kubernetes.lab.id
  node_pool_name = "workers"

  vswitch_ids = [
    alicloud_vswitch.lab.id
  ]

  # Use the first ECS instance type matching our requested CPU/RAM.
  instance_types = local.worker_instance_types

  # Pay-as-you-go is appropriate for a disposable learning environment.
  instance_charge_type = "PostPaid"

  desired_size = var.worker_count

  # Minimal, inexpensive system disk.
  system_disk_category = "cloud_efficiency"
  system_disk_size     = 40

  # Do not install extra CloudMonitor agent in this small lab.
  install_cloud_monitor = false

  # Standard Alibaba Cloud Linux image for ACK workers.
  image_type = "AliyunLinux3ContainerOptimized"
}


###############################################################################
# kubeconfig
###############################################################################

# Download a kubeconfig after the cluster and workers exist.
#
# kubectl reads this file to find the API server address and credentials.
data "alicloud_cs_cluster_credential" "lab" {
  cluster_id = alicloud_cs_managed_kubernetes.lab.id

  # Write the credential into this project directory.
  output_file = "${path.module}/kubeconfig"

  depends_on = [
    alicloud_cs_kubernetes_node_pool.workers
  ]
}


###############################################################################
# Useful outputs
###############################################################################

output "cluster_id" {
  description = "Alibaba Cloud ACK cluster ID"
  value       = alicloud_cs_managed_kubernetes.lab.id
}

output "region" {
  value = var.region
}

output "availability_zone" {
  value = data.alicloud_zones.available.zones[0].id
}

output "preferred_2c4g_instance_types" {
  description = "2C4G worker candidates, cheapest first"
  value       = local.worker_2c4g_types
}

output "fallback_4c4g_instance_types" {
  description = "4C4G fallback candidates, cheapest first"
  value       = local.worker_4c4g_types
}

output "worker_instance_type_priority" {
  description = "Complete ordered instance type fallback list used by ACK"
  value       = local.worker_instance_types
}

output "worker_count" {
  value = var.worker_count
}

output "kubeconfig" {
  value = "${path.module}/kubeconfig"
}
