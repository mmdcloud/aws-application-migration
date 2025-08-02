variable "source_region" {
  type    = string
  default = "us-east-1"
}

variable "dest_region" {
  type    = string
  default = "us-central1"
}

variable "source_public_subnets" {
  type    = list(string)
  default = ["10.0.1.10/24", "10.0.1.20/24", "10.0.1.30/24"]
}

variable "source_private_subnets" {
  type    = list(string)
  default = ["10.0.1.40/24", "10.0.1.50/24", "10.0.1.60/24"]
}
