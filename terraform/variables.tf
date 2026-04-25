variable "source_region" {
  type    = string
  default = "us-central1"
}

variable "dest_region" {
  type    = string
  default = "us-east-1"
}

variable "source_public_subnets" {
  type    = list(string)
  default = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
}

variable "source_private_subnets" {
  type    = list(string)
  default = ["10.0.4.0/24", "10.0.5.0/24", "10.0.6.0/24"]
}

variable "destination_public_subnets" {
  type        = list(string)
  description = "Public Subnet CIDR values"
}

variable "destination_private_subnets" {
  type        = list(string)
  description = "Private Subnet CIDR values"
}

variable "destination_database_subnets" {
  type        = list(string)
  description = "Private Subnet CIDR values"
}

variable "destination_azs" {
  type        = list(string)
  description = "Availability Zones"
}

variable "project_name" {
  type    = string
  default = "gcp-aws-vm-migration"
}

output "target_vpc_id" {
  description = "AWS target VPC ID"
  value       = aws_vpc.target.id
}

output "target_public_subnet_id" {
  description = "Public subnet ID (staging replication servers + migrated instance)"
  value       = aws_subnet.target_public.id
}

variable "target_instance_type" {
  type        = string
  default     = "t3.micro"
  description = "EC2 instance type for the migrated instance (equivalent to GCP e2-micro)"
}

output "target_private_subnet_id" {
  description = "Private subnet ID (optional post-cutover placement)"
  value       = aws_subnet.target_private.id
}

output "mgn_replication_template_id" {
  description = "MGN replication configuration template ID"
  value       = aws_mgn_replication_configuration_template.main.id
}

output "mgn_agent_iam_user" {
  description = "IAM user name for MGN replication agent on GCP source"
  value       = aws_iam_user.mgn_agent.name
}

output "mgn_agent_credentials_secret_arn" {
  description = "Secrets Manager ARN — retrieve agent access key/secret here"
  value       = aws_secretsmanager_secret.mgn_agent_credentials.arn
  sensitive   = true
}

output "mgn_staging_bucket" {
  description = "S3 bucket used for MGN staging area"
  value       = aws_s3_bucket.mgn_staging.id
}

output "replication_server_sg_id" {
  description = "Security group ID for MGN replication servers"
  value       = aws_security_group.mgn_replication_server.id
}

output "migrated_instance_sg_id" {
  description = "Security group ID for the migrated EC2 instance"
  value       = aws_security_group.migrated_instance.id
}

output "source_gcp_vm_public_ip" {
  description = "GCP source instance public IP — must be whitelisted in replication SG"
  value       = google_compute_address.source_instance_ip.address
}

output "nat_gateway_eip" {
  description = "EIP attached to the NAT gateway"
  value       = aws_eip.nat.public_ip
}

output "agent_install_command" {
  description = "Command to run on GCP VM to install MGN replication agent"
  value       = <<-EOT
    # 1. Get credentials from Secrets Manager:
    #    aws secretsmanager get-secret-value --secret-id mgn/agent-credentials --region us-east-1
    #
    # 2. SSH into GCP VM and run:
    #    wget -O ./aws-replication-installer-init.py \
    #      https://aws-application-migration-service-us-east-1.s3.us-east-1.amazonaws.com/latest/linux/aws-replication-installer-init.py
    #    sudo python3 aws-replication-installer-init.py \
    #      --region us-east-1 \
    #      --aws-access-key-id <ACCESS_KEY> \
    #      --aws-secret-access-key <SECRET_KEY> \
    #      --no-prompt
  EOT
}