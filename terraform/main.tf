# -------------------------------------------------------------------
# GCP Configuration
# -------------------------------------------------------------------

# VPC Creation
module "source_vpc" {
  source                  = "./modules/gcp/network/vpc"
  auto_create_subnetworks = false
  vpc_name                = "source-vpc"
  routing_mode            = "REGIONAL"
}

# Subnets Creation
module "source_vpc_public_subnets" {
  source                   = "./modules/gcp/network/subnet"
  name                     = "source-public-subnet"
  subnets                  = var.source_public_subnets
  vpc_id                   = module.source_vpc.vpc_id
  private_ip_google_access = false
  location                 = var.source_location
}

module "source_vpc_private_subnets" {
  source                   = "./modules/gcp/network/subnet"
  name                     = "source-private-subnet"
  subnets                  = var.source_private_subnets
  vpc_id                   = module.source_vpc.vpc_id
  private_ip_google_access = true
  location                 = var.source_location
}

# -------------------------------------------------------------------
# AWS Configuration
# -------------------------------------------------------------------

# VPC Configuration
module "destination_vpc" {
  source                = "./modules/aws/vpc/vpc"
  vpc_name              = "destination-vpc"
  vpc_cidr_block        = "0.0.0.0/0"
  enable_dns_hostnames  = true
  enable_dns_support    = true
  internet_gateway_name = "destination_vpc_igw"
}

# RDS Security Group
module "destination_rds_sg" {
  source = "./modules/aws/vpc/security_groups"
  vpc_id = module.destination_vpc.vpc_id
  name   = "destination_rds_sg"
  ingress = [
    {
      from_port       = 3306
      to_port         = 3306
      protocol        = "tcp"
      self            = "false"
      cidr_blocks     = ["10.0.0.0/16"]
      security_groups = []
      description     = "MySQL from VPC"
    }
  ]
  egress = [
    {
      from_port   = 0
      to_port     = 0
      protocol    = "-1"
      cidr_blocks = ["0.0.0.0/0"]
    }
  ]
}

# Public Subnets
module "destination_public_subnets" {
  source = "./modules/aws/vpc/subnets"
  name   = "destination public subnet"
  subnets = [
    {
      subnet = "10.0.1.0/24"
      az     = "us-east-1a"
    },
    {
      subnet = "10.0.2.0/24"
      az     = "us-east-1b"
    },
    {
      subnet = "10.0.3.0/24"
      az     = "us-east-1c"
    }
  ]
  vpc_id                  = module.destination_vpc.vpc_id
  map_public_ip_on_launch = true
}

# Private Subnets
module "destination_private_subnets" {
  source = "./modules/aws/vpc/subnets"
  name   = "destination private subnet"
  subnets = [
    {
      subnet = "10.0.4.0/24"
      az     = "us-east-1a"
    },
    {
      subnet = "10.0.5.0/24"
      az     = "us-east-1b"
    },
    {
      subnet = "10.0.6.0/24"
      az     = "us-east-1c"
    }
  ]
  vpc_id                  = module.destination_vpc.vpc_id
  map_public_ip_on_launch = false
}

# Destination Public Route Table
module "destination_public_rt" {
  source  = "./modules/aws/vpc/route_tables"
  name    = "destination public route table"
  subnets = module.destination_public_subnets.subnets[*]
  routes = [
    {
      cidr_block     = "0.0.0.0/0"
      gateway_id     = module.destination_vpc.igw_id
      nat_gateway_id = ""
    }
  ]
  vpc_id = module.destination_vpc.vpc_id
}

# Destination Private Route Table
module "destination_private_rt" {
  source  = "./modules/aws/vpc/route_tables"
  name    = "destination private route table"
  subnets = module.destination_private_subnets.subnets[*]
  routes  = []
  vpc_id  = module.destination_vpc.vpc_id
}
