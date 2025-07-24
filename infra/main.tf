/*
resource "aws_eks_cluster" "cluster" {
  name = "${var.name}-cluster"

  access_config {
    authentication_mode = "API"
  }

  role_arn = ""
  version  = "1.33"

  bootstrap_self_managed_addons = false

  compute_config {
    enabled = true
  }

  kubernetes_network_config {
    elastic_load_balancing {
      enabled = true
    }
  }

  storage_config {
    block_storage {
      enabled = true
    }
  }

  vpc_config {
    subnet_ids = []
  }

}
*/