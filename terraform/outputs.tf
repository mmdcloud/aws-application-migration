
output "target_vpc_id" {
  description = "AWS target VPC ID"
  value       = module.destination_vpc.vpc_id
}

output "target_public_subnet_id" {
  description = "Public subnet ID (staging replication servers + migrated instance)"
  value       = module.destination_vpc.public_subnets
}

variable "target_instance_type" {
  type        = string
  default     = "t3.micro"
  description = "EC2 instance type for the migrated instance (equivalent to GCP e2-micro)"
}

output "target_private_subnet_id" {
  description = "Private subnet ID (optional post-cutover placement)"
  value       = module.destination_vpc.private_subnets
}

output "mgn_agent_iam_user" {
  description = "IAM user name for MGN replication agent on GCP source"
  value       = aws_iam_user.mgn_agent.name
}

output "mgn_staging_bucket" {
  description = "S3 bucket used for MGN staging area"
  value       = aws_s3_bucket.mgn_staging.id
}

output "replication_server_sg_id" {
  description = "Security group ID for MGN replication servers"
  value       = module.mgn_replication_server_sg.id
}

output "migrated_instance_sg_id" {
  description = "Security group ID for the migrated EC2 instance"
  value       = module.migrated_instance_sg.id
}

output "source_gcp_vm_public_ip" {
  description = "GCP source instance public IP — must be whitelisted in replication SG"
  value       = google_compute_address.source_instance_ip.address
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