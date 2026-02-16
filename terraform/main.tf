terraform {
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.45"
    }
  }
}

variable "hcloud_token" {
  description = "Hetzner Cloud API token"
  type        = string
  sensitive   = true
}

variable "server_name" {
  description = "Name of the server"
  type        = string
  default     = "agent-vps"
}

variable "server_type" {
  description = "Hetzner server type (CPX11=2vCPU/4GB, CPX21=4vCPU/8GB, CPX31=4vCPU/16GB)"
  type        = string
  default     = "cpx21"
}

variable "location" {
  description = "Hetzner location (ash=Ashburn, nbg=Nuremberg, fsn=Falkenstein, hel=Helsinki)"
  type        = string
  default     = "ash"
}

variable "ssh_public_key" {
  description = "SSH public key for server access"
  type        = string
}

provider "hcloud" {
  token = var.hcloud_token
}

# SSH Key resource
resource "hcloud_ssh_key" "default" {
  name       = "${var.server_name}-key"
  public_key = var.ssh_public_key
}

# Server resource
resource "hcloud_server" "agent_vps" {
  name        = var.server_name
  server_type = var.server_type
  image       = "ubuntu-24.04"
  location    = var.location
  ssh_keys    = [hcloud_ssh_key.default.id]

  labels = {
    environment = "production"
    managed_by  = "terraform"
    purpose     = "coding-agents"
  }

  # User data to run initial setup
  user_data = templatefile("${path.module}/cloud-init.yml", {
    server_name = var.server_name
  })
}

# Firewall for security
resource "hcloud_firewall" "agent_vps" {
  name = "${var.server_name}-firewall"

  # SSH
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "22"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  # HTTP
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "80"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  # HTTPS
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "443"
    source_ips = ["0.0.0.0/0", "::/0"]
  }
}

# Attach firewall to server
resource "hcloud_firewall_attachment" "agent_vps" {
  firewall_id = hcloud_firewall.agent_vps.id
  server_ids  = [hcloud_server.agent_vps.id]
}

# Outputs
output "server_ip" {
  description = "IPv4 address of the server"
  value       = hcloud_server.agent_vps.ipv4_address
}

output "server_name" {
  description = "Name of the created server"
  value       = hcloud_server.agent_vps.name
}

output "ssh_command" {
  description = "Command to SSH into the server"
  value       = "ssh ubuntu@${hcloud_server.agent_vps.ipv4_address}"
}

output "setup_next_steps" {
  description = "Next steps after server creation"
  value       = <<-EOT

Server created! Next steps:

1. Wait 2-3 minutes for cloud-init to complete

2. SSH into the server:
   ssh ubuntu@${hcloud_server.agent_vps.ipv4_address}

3. Run the VPS setup script:
   sudo ./setup.sh --on-server

To destroy (stops billing):
   terraform destroy
EOT
}
