resource "aws_launch_template" "template" {
  name          = var.name
  description   = var.description
  image_id      = var.image_id
  instance_type = var.instance_type
  key_name      = var.key_name
  ebs_optimized = var.ebs_optimized
  iam_instance_profile {
    name = var.instance_profile_name
  }
  dynamic "tag_specifications" {
    for_each = var.tag_specs
    content {
      resource_type = tag_specifications.value.resource_type
      tags          = tag_specifications.value.tags
    }
  }
  metadata_options {
    http_endpoint               = var.instance_metadata_options.http_endpoint
    http_tokens                 = var.instance_metadata_options.http_tokens
    http_put_response_hop_limit = var.instance_metadata_options.http_put_response_hop_limit
  }
  instance_initiated_shutdown_behavior = var.instance_initiated_shutdown_behavior
  monitoring {
    enabled = var.monitoring_enabled
  }
  dynamic "network_interfaces" {
    for_each = var.network_interfaces
    content {
      associate_public_ip_address = network_interfaces.value["associate_public_ip_address"]
      security_groups             = network_interfaces.value["security_groups"]
    }
  }
  user_data = var.user_data
  tags = var.tags
}
