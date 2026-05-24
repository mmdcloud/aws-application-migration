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