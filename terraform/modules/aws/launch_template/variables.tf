variable "name" {}
variable "description" {}
variable "image_id" {}
variable "instance_type" {}
variable "key_name" {}
variable "ebs_optimized" {}
variable "instance_initiated_shutdown_behavior" {}
variable "instance_profile_name" {}
variable "monitoring_enabled" {
  type    = bool
  default = false
}
variable "network_interfaces" {
  type = list(object({
    associate_public_ip_address = bool
    security_groups             = list(string)
  }))
}
variable "user_data" {

}
variable "instance_metadata_options" {
  description = "Configuration for the instance metadata service (IMDS)"
  type = object({
    http_endpoint               = string
    http_tokens                 = string
    http_put_response_hop_limit = number
  })
  default = {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # Enforces IMDSv2
    http_put_response_hop_limit = 1
  }
}
variable "tags" {
  type    = map(string)
  default = {}
}
variable "tag_specs" {
  description = "List of tag specifications for the resource"
  type = list(object({
    resource_type = string
    tags          = map(string)
  }))
  default = []
}