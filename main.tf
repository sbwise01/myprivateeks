terraform {
  required_version = "~> 0.12"

  backend "remote" {
    hostname = "console.tfe.aws.bradandmarsha.com"
    organization = "bradtest"

    workspaces {
      name = "myprivateeks"
    }
  }
}

variable "vpc_id" {
  type        = string
  description = "VPC ID that TFE Agent will be deployed into."
}

variable "private_subnets_tag_key" {
  type        = string
  description = "The tag:key of private subnets."
}

variable "private_subnets_tag_value" {
  type        = string
  description = "The value of private subnets tag."
}

variable "ingress_agent_pool_443_allow" {
  type        = string
  description = "Security Group ID to allow ingress traffic on port 443 to EKS cluster from TFE agent pool."
}

data "aws_caller_identity" "current" {}

data "aws_eks_cluster" "eks" {
  name = module.eks.cluster_id
}

data "aws_eks_cluster_auth" "eks" {
  name = module.eks.cluster_id
}

data "aws_vpc" "selected" {
  id = var.vpc_id
}

data "aws_subnet_ids" "private" {
  vpc_id = data.aws_vpc.selected.id
  filter {
    name   = "tag:${var.private_subnets_tag_key}"
    values = [var.private_subnets_tag_value]
  }
}

provider "aws" {
  region  = "us-east-1"
}

provider "kubernetes" {
  alias                  = "eks"
  host                   = data.aws_eks_cluster.eks.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.eks.certificate_authority.0.data)
  token                  = data.aws_eks_cluster_auth.eks.token
  load_config_file       = false
  version                = "1.11.1"
}

locals {
  cluster_name = "bwtest-eks-tzBq"
  tags         = {
    Name        = "bwtest"
    Terraform   = "true"
    Environment = "poc"
  }
  eks_map_accounts = list(data.aws_caller_identity.current.account_id)
}

module "eks" {
  # SSH based source
  # source = "git@github.com:terraform-aws-modules/terraform-aws-eks.git?ref=v9.0.0"
  source = "github.com/terraform-aws-modules/terraform-aws-eks.git?ref=v9.0.0"

  providers = {
    kubernetes = kubernetes.eks
  }

  manage_aws_auth                 = true
  cluster_name                    = local.cluster_name
  subnets                         = data.aws_subnet_ids.private.ids
  vpc_id                          = data.aws_vpc.selected.id
  cluster_endpoint_public_access  = false
  cluster_endpoint_private_access = true
  write_kubeconfig                = false
  cluster_version = "1.19"
  map_roles       = [
    {
      rolearn = "arn:aws:iam::238080251717:role/test-assumed-1"
      username = "test-assumed-1"
      groups = ["system:masters"]
    }
  ]

  workers_additional_policies = [
  ]

  worker_groups = [
    {
      instance_type         = "c5.large"
      disk_size             = "5Gi"
      asg_desired_capacity  = 3
      asg_min_size          = 3
      asg_max_size          = 3
      autoscaling_enabled   = false
      protect_from_scale_in = false
    },
  ]

  workers_group_defaults = {
    tags = [
      {
        key                 = "k8s.io/cluster-autoscaler/enabled"
        value               = "true"
        propagate_at_launch = true
      },
      {
        key                 = "k8s.io/cluster-autoscaler/${local.cluster_name}"
        value               = "true"
        propagate_at_launch = true
      }
    ]
  }

  cluster_enabled_log_types = [
    "api",
    "audit",
    "authenticator",
    "controllerManager",
    "scheduler"
  ]

  map_accounts    = local.eks_map_accounts
  create_eks      = true
  enable_irsa     = true

  tags = merge(local.tags, map("kubernetes.io/cluster/${local.cluster_name}", "shared"))
}

resource "aws_security_group_rule" "private_api_ingress" {
  description              = "Allow agent pool to communicate with the EKS cluster API."
  protocol                 = "tcp"
  security_group_id        = module.eks.cluster_security_group_id
  source_security_group_id = var.ingress_agent_pool_443_allow
  from_port                = 443
  to_port                  = 443
  type                     = "ingress"
}
