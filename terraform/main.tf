# -------------------------------------------------------------------
# GCP Configuration
# -------------------------------------------------------------------

# VPC Configuration
module "source_vpc" {
  source                          = "./modules/vpc"
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

# Instance 1
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
