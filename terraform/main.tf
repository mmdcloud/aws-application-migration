# -------------------------------------------------------------------
# GCP Configuration
# -------------------------------------------------------------------
module "source_vpc" {
  source                          = "./modules/gcp/vpc"
  vpc_name                        = "source-vpc"
  delete_default_routes_on_create = false
  auto_create_subnetworks         = false
  routing_mode                    = "REGIONAL"
  region                          = var.location
  subnets                         = []
  firewall_data                   = []
}

resource "google_compute_address" "source_instance_ip" {
  name = "source-instance-ip"
}

module "source_instance" {
  source                    = "./modules/gcp/compute"
  name                      = "source-instance"
  machine_type              = "e2-micro"
  zone                      = "us-central1-a"
  metadata_startup_script   = "sudo apt-get update; sudo apt-get install nginx -y"
  deletion_protection       = false
  allow_stopping_for_update = true
  image                     = "ubuntu-os-cloud/ubuntu-2004-focal-v20220712"
  network_interfaces = [
    {
      network    = module.source_vpc.vpc_id
      subnetwork = module.source_vpc_public_subnets.subnets[0].id
      access_configs = [
        {
          nat_ip = google_compute_address.source_instance_ip.address
        }
      ]
    }
  ]
}

# -------------------------------------------------------------------
# AWS Configuration
# -------------------------------------------------------------------
module "destination_vpc" {
  source                  = "./modules/aws/vpc"
  vpc_name                = "destination-vpc"
  vpc_cidr                = "10.0.0.0/16"
  azs                     = var.destination_azs
  public_subnets          = var.destination_public_subnets
  private_subnets         = var.destination_private_subnets
  database_subnets        = var.destination_database_subnets
  enable_dns_hostnames    = true
  enable_dns_support      = true
  create_igw              = true
  map_public_ip_on_launch = true
  enable_nat_gateway      = true
  single_nat_gateway      = false
  one_nat_gateway_per_az  = true
  tags = {
    Project = var.project_name
  }
}

# -------------------------------------------------------------------
# AWS Application Migration Service (MGN)
# -------------------------------------------------------------------

# Initialize MGN in this account/region
# This is idempotent — safe to apply even if MGN is already initialized.
resource "aws_mgn_replication_configuration_template" "main" {
  replication_server_instance_type = var.mgn_replication_server_instance_type

  # Replication servers live in the public subnet so they have internet
  # access to reach GCP source agent over TCP 1500.
  replication_servers_security_groups_ids = [
    module.mgn_replication_server_sg.id
  ]

  staging_area_subnet_id = aws_subnet.target_public.id
  staging_area_tags      = var.mgn_staging_area_tags

  # Use your own S3 bucket for staging (optional — MGN can manage its own)
  # Remove this block to let MGN use its auto-created bucket.
  # Keeping it here for auditability.

  associate_default_security_group = false

  bandwidth_throttling = 0 # 0 = unlimited; set MB/s if source has limited uplink

  create_public_ip = true # replication servers need public IPs so source agent can reach them

  data_plane_routing              = "PUBLIC_IP" # use PRIVATE_IP if you have VPN/Direct Connect
  default_large_staging_disk_type = "GP3"

  ebs_encryption = "DEFAULT" # AWS-managed keys; switch to CUSTOM + KMS ARN for CMK

  use_dedicated_replication_server = false # true = dedicated EC2, more expensive

  replication_configuration_template_id = null # auto-assigned

  tags = {
    Name    = "${var.project_name}-replication-template"
    Project = var.project_name
  }

  depends_on = [
    aws_iam_service_linked_role.mgn,
    aws_iam_instance_profile.mgn_replication_server
  ]
}

# -------------------------------------------------------------------
# Launch Template — defines EC2 config for test / cutover instances
# -------------------------------------------------------------------

resource "aws_mgn_launch_configuration_template" "main" {
  # Associate migrated instance with the target subnet
  target_instance_type_right_sizing_method = "NONE" # BASIC = auto right-size; NONE = use your defined type

  tags = {
    Name    = "${var.project_name}-launch-template"
    Project = var.project_name
  }

  launch_disposition = "STOPPED" # launch in STOPPED state; change to STARTED for cutover auto-start

  # Post-launch actions — run SSM documents after launch
  post_launch_actions {
    deployment    = "TEST_AND_CUTOVER"
    s3_log_bucket = aws_s3_bucket.mgn_staging.bucket

    ssm_documents {
      action_name              = "InstallSSMAgent"
      ssm_document             = "AWS-ConfigureAWSPackage"
      timeout_seconds          = 300
      must_succeed_for_cutover = true

      parameters {
        parameter_name = "action"
        parameter_type = "STRING"
        parameters     = ["Install"]
      }

      parameters {
        parameter_name = "name"
        parameter_type = "STRING"
        parameters     = ["AmazonSSMAgent"]
      }
    }
  }

  depends_on = [aws_mgn_replication_configuration_template.main]
}

# -------------------------------------------------------------------
# Source Server
# NOTE: aws_mgn_source_server is registered automatically when the
# MGN agent runs on the GCP VM. Terraform can import it after agent
# registration, or you can use a null_resource to trigger agent install.
#
# The resource below pre-creates the server entry — MGN will match
# the agent registration to this entry via the source server ID.
# -------------------------------------------------------------------

resource "aws_mgn_source_server" "gcp_vm" {
  source_server_id = null # populated by MGN after agent registers; import via terraform import

  lifecycle_state = "READY_FOR_TEST" # valid after initial sync: NOT_READY → READY_FOR_TEST → READY_FOR_CUTOVER

  tags = {
    Name          = "source-instance-gcp"
    SourceVM      = "gcp/us-central1-a/source-instance"
    Project       = var.project_name
    MigrationType = "lift-and-shift"
  }
}

# Per-source-server launch configuration
# Applied after aws_mgn_source_server is imported.
resource "aws_mgn_launch_configuration" "gcp_vm" {
  source_server_id = aws_mgn_source_server.gcp_vm.id

  copy_private_ip    = false
  copy_tags          = true
  launch_disposition = "STOPPED"

  # Target instance type matching e2-micro (~1 vCPU, 1GB RAM)
  target_instance_type_right_sizing_method = "NONE"

  enable_map_auto_tagging = true

  # EC2 launch template overrides applied to the migrated instance
  ec2_launch_template_id = aws_launch_template.migrated_instance.id
}

# Per-source-server replication configuration
resource "aws_mgn_replication_configuration" "gcp_vm" {
  source_server_id = aws_mgn_source_server.gcp_vm.id

  replication_configuration_template_id = aws_mgn_replication_configuration_template.main.id

  # Replicate all disks (boot + data)
  replicated_disks {
    device_name       = "/dev/sda1" # Ubuntu root disk device name on GCP
    iops              = 3000
    throughput        = 125
    volume_type       = "gp3"
    staging_disk_type = "GP3"
  }

  bandwidth_throttling             = 0
  create_public_ip                 = true
  data_plane_routing               = "PUBLIC_IP"
  default_large_staging_disk_type  = "GP3"
  ebs_encryption                   = "DEFAULT"
  replication_server_instance_type = var.mgn_replication_server_instance_type

  replication_servers_security_groups_ids = [
    module.mgn_replication_server_sg.id
  ]

  staging_area_subnet_id = aws_subnet.target_public.id
  staging_area_tags      = var.mgn_staging_area_tags

  use_dedicated_replication_server = false
  use_fips_endpoint                = false
}

# -------------------------------------------------------------------
# IAM — MGN Service Roles
# MGN requires three pre-created IAM roles before initialization.
# -------------------------------------------------------------------

# 1. AWSApplicationMigrationServiceRole  (MGN service-linked role)
#    Usually created automatically when MGN is initialized, but we
#    create it explicitly so Terraform owns it.
resource "aws_iam_service_linked_role" "mgn" {
  aws_service_name = "mgn.amazonaws.com"
  description      = "Service-linked role for AWS Application Migration Service"
}

# 2. AWSApplicationMigrationReplicationServerRole
#    Attached to replication server instances — allows them to call
#    MGN APIs and write to S3 staging.
module "mgn_replication_server" {
  source             = "./modules/aws/iam"
  role_name          = "AWSApplicationMigrationReplicationServerRole"
  role_description   = "AWSApplicationMigrationReplicationServerRole"
  policy_name        = "AWSApplicationMigrationReplicationServerRolePolicy"
  policy_description = "AWSApplicationMigrationReplicationServerRolePolicy"
  assume_role_policy = <<EOF
    {
        "Version": "2012-10-17",
        "Statement": [
            {
                "Action": "sts:AssumeRole",
                "Principal": {
                  "Service": "ec2.amazonaws.com"
                },
                "Effect": "Allow",
                "Sid": ""
            }
        ]
    }
    EOF
  policy             = <<EOF
    {
        "Version": "2012-10-17",
        "Statement": [
            {
                "Action": [
                  "mgn:SendClientMetricsForMgn",
                  "mgn:RegisterAgentForMgn",
                  "mgn:GetChannelCommandsForMgn",
                  "mgn:SendChannelCommandResultForMgn",
                  "mgn:ListTagsForResource",
                  "ec2:DescribeInstances",
                  "ec2:DescribeVolumes",
                  "ec2:DescribeSnapshots",
                  "ec2:CreateTags",
                  "ec2:DescribeTags"
                ],
                "Resource": "*",
                "Effect": "Allow"
            },
            {
                "Action": [
                  "s3:GetObject",
                  "s3:PutObject",
                  "s3:ListBucket",
                  "s3:GetBucketLocation",
                  "s3:AbortMultipartUpload",
                  "s3:ListMultipartUploadParts"
                ],
                "Resource": [
                  "${aws_s3_bucket.mgn_staging.arn}",
                  "${aws_s3_bucket.mgn_staging.arn}/*"
                ],
                "Effect": "Allow"
            }
        ]
    }
    EOF
  tags = {
    Name    = "mgn-replication-server-role"
    Project = var.project_name
  }
}

resource "aws_iam_role_policy_attachment" "mgn_replication_server" {
  role       = module.mgn_replication_server.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "mgn_replication_server" {
  name = "AWSApplicationMigrationReplicationServerRole"
  role = module.mgn_replication_server.name
}

# 3. AWSApplicationMigrationEC2Access
#    Used by MGN to launch test/cutover instances on your behalf.
resource "aws_iam_role" "mgn_conversion_server" {
  name = "AWSApplicationMigrationConversionServerRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "ec2.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name    = "mgn-conversion-server-role"
    Project = var.project_name
  }
}

resource "aws_iam_role_policy_attachment" "mgn_conversion_ssm" {
  role       = aws_iam_role.mgn_conversion_server.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "mgn_conversion_server" {
  name = "AWSApplicationMigrationConversionServerRole"
  role = aws_iam_role.mgn_conversion_server.name
}

# 4. IAM user for MGN agent on source GCP instance
#    The AWS Replication Agent installed on the GCP VM uses these credentials
#    to authenticate to the MGN service.
resource "aws_iam_user" "mgn_agent" {
  name = "${var.project_name}-mgn-agent-user"
  path = "/mgn/"

  tags = {
    Name    = "mgn-agent-iam-user"
    Project = var.project_name
  }
}

resource "aws_iam_user_policy_attachment" "mgn_agent" {
  user       = aws_iam_user.mgn_agent.name
  policy_arn = "arn:aws:iam::aws:policy/AWSApplicationMigrationAgentPolicy"
}

# Access key — store the secret in Secrets Manager, NOT in state directly.
# Retrieve via: aws secretsmanager get-secret-value --secret-id mgn/agent-credentials
resource "aws_iam_access_key" "mgn_agent" {
  user = aws_iam_user.mgn_agent.name
}

module "mgn_agent_credentials" {
  source                  = "./modules/aws/secrets-manager"
  name                    = "mgn/agent-credentials"
  description             = "AWS access key used by MGN replication agent on GCP source instance"
  recovery_window_in_days = 7
  secret_string = jsonencode({
    access_key_id     = aws_iam_access_key.mgn_agent.id
    secret_access_key = aws_iam_access_key.mgn_agent.secret
  })
  tags = {
    Project = var.project_name
  }
}

# resource "aws_secretsmanager_secret" "mgn_agent_credentials" {
#   name                    = "mgn/agent-credentials"
#   description             = "AWS access key used by MGN replication agent on GCP source instance"
#   recovery_window_in_days = 7

#   tags = {
#     Project = var.project_name
#   }
# }

# resource "aws_secretsmanager_secret_version" "mgn_agent_credentials" {
#   secret_id = aws_secretsmanager_secret.mgn_agent_credentials.id
#   secret_string = jsonencode({
#     access_key_id     = aws_iam_access_key.mgn_agent.id
#     secret_access_key = aws_iam_access_key.mgn_agent.secret
#   })
# }

# -------------------------------------------------------------------
# Security Groups
# -------------------------------------------------------------------

# Replication server SG
# Inbound:  TCP 1500 from source GCP VM public IP (data channel)
# Outbound: all (needs to reach S3, MGN endpoints, EC2 APIs)
module "mgn_replication_server_sg" {
  source = "./modules/aws/security-groups"
  name   = "${var.project_name}-mgn-replication-sg"
  vpc_id = module.destination_vpc.vpc_id
  ingress_rules = [
    {
      description = "MGN data replication channel from source agent"
      from_port   = 1500
      to_port     = 1500
      protocol    = "tcp"
      cidr_blocks = ["${google_compute_address.source_instance_ip.address}/32"]
    }
  ]
  egress_rules = [
    {
      description = "Allow all outbound"
      from_port   = 0
      to_port     = 0
      protocol    = "-1"
      cidr_blocks = ["0.0.0.0/0"]
    }
  ]
  tags = {
    Name    = "${var.project_name}-replication-sg"
    Project = var.project_name
  }
}

module "migrated_instance_sg" {
  source = "./modules/aws/security-groups"
  name   = "${var.project_name}-migrated-instance-sg"
  vpc_id = module.destination_vpc.vpc_id
  ingress_rules = [
    {
      description = "HTTP (nginx)"
      from_port   = 80
      to_port     = 80
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
    },
    {
      description = "HTTPS"
      from_port   = 443
      to_port     = 443
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
    },
    {
      description = "SSH (restrict to your IP in production)"
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
    }
  ]
  egress_rules = [
    {
      from_port   = 0
      to_port     = 0
      protocol    = "-1"
      cidr_blocks = ["0.0.0.0/0"]
    }
  ]
  tags = {
    Name    = "${var.project_name}-migrated-sg"
    Project = var.project_name
  }
}

# -------------------------------------------------------------------
# S3 — MGN Staging Area Bucket
# MGN creates its own internal staging bucket, but we provision one
# explicitly so we control encryption and retention policy.
# -------------------------------------------------------------------

resource "aws_s3_bucket" "mgn_staging" {
  bucket        = "${var.project_name}-mgn-staging-${data.aws_caller_identity.current.account_id}"
  force_destroy = true # safe for staging — replication data is transient

  tags = {
    Name    = "${var.project_name}-mgn-staging"
    Project = var.project_name
  }
}

resource "aws_s3_bucket_versioning" "mgn_staging" {
  bucket = aws_s3_bucket.mgn_staging.id

  versioning_configuration {
    status = "Disabled" # staging data doesn't need versioning
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "mgn_staging" {
  bucket = aws_s3_bucket.mgn_staging.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "mgn_staging" {
  bucket                  = aws_s3_bucket.mgn_staging.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Lifecycle — auto-delete staging objects after 30 days
resource "aws_s3_bucket_lifecycle_configuration" "mgn_staging" {
  bucket = aws_s3_bucket.mgn_staging.id

  rule {
    id     = "expire-staging-data"
    status = "Enabled"

    expiration {
      days = 30
    }

    noncurrent_version_expiration {
      noncurrent_days = 7
    }
  }
}

data "aws_caller_identity" "current" {}

# -------------------------------------------------------------------
# EC2 Launch Template — used by MGN when launching test/cutover instances
# -------------------------------------------------------------------
data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

module "launch_template" {
  source                               = "./modules/aws/launch_template"
  name                                 = "${var.project_name}-migrated-"
  description                          = "${var.project_name}-migrated-"
  ebs_optimized                        = false
  image_id                             = data.aws_ami.amazon_linux_2023.id
  instance_type                        = var.target_instance_type
  instance_initiated_shutdown_behavior = "stop"
  instance_profile_name                = aws_iam_instance_profile.migrated_instance_ssm.name
  key_name                             = "madmaxkeypair"
  monitoring_enabled                   = true
  network_interfaces = [
    {
      associate_public_ip_address = true
      security_groups             = [module.migrated_instance_sg.id]
    }
  ]
  instance_metadata_options = {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }
  tag_specs = [
    {
      resource_type = "instance"
      tags = {
        Name     = "migrated-from-gcp-source-instance"
        Project  = var.project_name
        SourceVM = "gcp/us-central1-a/source-instance"
      }
    },
    {
      resource_type = "volume"
      tags = {
        Name    = "migrated-from-gcp-root-volume"
        Project = var.project_name
      }
    }
  ]
  user_data = base64encode(<<-EOT
    #!/bin/bash
    # Post-migration bootstrap
    # MGN converts the disk image, so nginx should already be installed.
    # This script handles any AWS-specific setup needed after cutover.

    # Install SSM agent (in case it wasn't on the source)
    snap install amazon-ssm-agent --classic || true
    systemctl enable snap.amazon-ssm-agent.amazon-ssm-agent.service
    systemctl start snap.amazon-ssm-agent.amazon-ssm-agent.service

    # Install CloudWatch agent
    wget -q https://s3.amazonaws.com/amazoncloudwatch-agent/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb
    dpkg -i amazon-cloudwatch-agent.deb

    # Ensure nginx is running (should already be from GCP startup script)
    systemctl enable nginx
    systemctl start nginx
  EOT
  )
  tags = {
    Name    = "${var.project_name}-launch-template"
    Project = var.project_name
  }
}

# resource "aws_launch_template" "migrated_instance" {
#   name_prefix   = "${var.project_name}-migrated-"
#   instance_type = var.target_instance_type

#   # MGN overwrites the AMI at launch with the converted snapshot.
#   # This AMI is a fallback only.
#   image_id = data.aws_ami.amazon_linux_2023.id

#   vpc_security_group_ids = [module.migrated_instance_sg.id]

#   iam_instance_profile {
#     name = aws_iam_instance_profile.migrated_instance_ssm.name
#   }

#   metadata_options {
#     http_endpoint               = "enabled"
#     http_tokens                 = "required" # IMDSv2 enforced
#     http_put_response_hop_limit = 1
#   }

#   monitoring {
#     enabled = true
#   }
#   tag_specifications {
#     resource_type = "instance"
#     tags = {
#       Name     = "migrated-from-gcp-source-instance"
#       Project  = var.project_name
#       SourceVM = "gcp/us-central1-a/source-instance"
#     }
#   }

#   tag_specifications {
#     resource_type = "volume"
#     tags = {
#       Name    = "migrated-from-gcp-root-volume"
#       Project = var.project_name
#     }
#   }

#   user_data = base64encode(<<-EOT
#     #!/bin/bash
#     # Post-migration bootstrap
#     # MGN converts the disk image, so nginx should already be installed.
#     # This script handles any AWS-specific setup needed after cutover.

#     # Install SSM agent (in case it wasn't on the source)
#     snap install amazon-ssm-agent --classic || true
#     systemctl enable snap.amazon-ssm-agent.amazon-ssm-agent.service
#     systemctl start snap.amazon-ssm-agent.amazon-ssm-agent.service

#     # Install CloudWatch agent
#     wget -q https://s3.amazonaws.com/amazoncloudwatch-agent/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb
#     dpkg -i amazon-cloudwatch-agent.deb

#     # Ensure nginx is running (should already be from GCP startup script)
#     systemctl enable nginx
#     systemctl start nginx
#   EOT
#   )

#   tags = {
#     Name    = "${var.project_name}-launch-template"
#     Project = var.project_name
#   }

#   lifecycle {
#     create_before_destroy = true
#   }
# }

# SSM instance profile for migrated EC2
resource "aws_iam_role" "migrated_instance_ssm" {
  name = "${var.project_name}-migrated-instance-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "ec2.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "migrated_ssm" {
  role       = aws_iam_role.migrated_instance_ssm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "migrated_cw" {
  role       = aws_iam_role.migrated_instance_ssm.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_instance_profile" "migrated_instance_ssm" {
  name = "${var.project_name}-migrated-instance-profile"
  role = aws_iam_role.migrated_instance_ssm.name
}
