terraform {
  required_version = ">= 0.11.8"
}

data "terraform_remote_state" "vpc" {
  backend = "atlas"
  config {
    name = "meta7poc/hub-vpc"
  }
}

provider "random" {
  version = "= 1.3.1"
}

data "aws_availability_zones" "available" {}

locals {
  cluster_name = "test-eks-${random_string.suffix.result}"

  # the commented out worker group list below shows an example of how to define
  # multiple worker groups of differing configurations
  # worker_groups = [
  #   {
  #     asg_desired_capacity = 2
  #     asg_max_size = 10
  #     asg_min_size = 2
  #     instance_type = "m4.xlarge"
  #     name = "worker_group_a"
  #     additional_userdata = "echo foo bar"
  #     subnets = "${join(",", module.vpc.private_subnets)}"
  #   },
  #   {
  #     asg_desired_capacity = 1
  #     asg_max_size = 5
  #     asg_min_size = 1
  #     instance_type = "m4.2xlarge"
  #     name = "worker_group_b"
  #     additional_userdata = "echo foo bar"
  #     subnets = "${join(",", module.vpc.private_subnets)}"
  #   },
  # ]


  # the commented out worker group tags below shows an example of how to define
  # custom tags for the worker groups ASG
  # worker_group_tags = {
  #   worker_group_a = [
  #     {
  #       key                 = "k8s.io/cluster-autoscaler/node-template/taint/nvidia.com/gpu"
  #       value               = "gpu:NoSchedule"
  #       propagate_at_launch = true
  #     },
  #   ],
  #   worker_group_b = [
  #     {
  #       key                 = "k8s.io/cluster-autoscaler/node-template/taint/nvidia.com/gpu"
  #       value               = "gpu:NoSchedule"
  #       propagate_at_launch = true
  #     },
  #   ],
  # }

  worker_groups = [
    {
      # This will launch an autoscaling group with only On-Demand instances
      instance_type        = "t2.nano"
      additional_userdata  = "${data.template_file.user_data_consul.rendered}"
      subnets              = "${join(",", data.terraform_remote_state.vpc.private_subnets)}"
      asg_desired_capacity = "2"
    },
  ]
  worker_groups_launch_template = [
    {
      # This will launch an autoscaling group with only Spot Fleet instances
      instance_type                            = "t2.micro"
      additional_userdata                      = "${data.template_file.user_data_consul.rendered}"
      subnets                                  = "${join(",", data.terraform_remote_state.vpc.private_subnets)}"
      additional_security_group_ids            = "${aws_security_group.worker_group_mgmt_one.id},${aws_security_group.worker_group_mgmt_two.id}"
      asg_desired_capacity                     = "2"
      spot_instance_pools                      = 10
      on_demand_percentage_above_base_capacity = "0"
    },
  ]
  tags = {
    Environment = "test"
    GithubRepo  = "terraform-aws-eks"
    GithubOrg   = "terraform-aws-modules"
    consul-cluster = "${var.consul_cluster_tag_key}" = "${var.consul_cluster_name}"
  }
}

resource "random_string" "suffix" {
  length  = 8
  special = false
}

resource "aws_security_group" "worker_group_mgmt_one" {
  name_prefix = "worker_group_mgmt_one"
  description = "SG to be applied to all *nix machines"
  vpc_id      = "${data.terraform_remote_state.vpc.vpc_id}"

  ingress {
    from_port = 22
    to_port   = 22
    protocol  = "tcp"

    cidr_blocks = [
      "10.0.0.0/8",
      "192.168.0.0/16",
    ]
  }
}

resource "aws_security_group" "worker_group_mgmt_two" {
  name_prefix = "worker_group_mgmt_two"
  vpc_id      = "${data.terraform_remote_state.vpc.vpc_id}"

  ingress {
    from_port = 22
    to_port   = 22
    protocol  = "tcp"

    cidr_blocks = [
      "10.0.0.0/8",
      "192.168.0.0/16",
    ]
  }
}

resource "aws_security_group" "all_worker_mgmt" {
  name_prefix = "all_worker_management"
  vpc_id      = "${data.terraform_remote_state.vpc.vpc_id}"

  ingress {
    from_port = 22
    to_port   = 22
    protocol  = "tcp"

    cidr_blocks = [
      "10.0.0.0/8",
      "172.16.0.0/12",
      "192.168.0.0/16",
    ]
  }
}

data "template_file" "user_data_consul" {
  template = "${file("${path.module}/user-data-consul.sh")}"

  vars {
    consul_cluster_tag_key   = "${var.consul_cluster_tag_key}"
    consul_cluster_tag_value = "${var.consul_cluster_name}"
  }
}

module "eks" {
  source  = "app.terraform.io/meta7poc/eks/aws"
  version = "2.1.0"
  manage_aws_auth                      = "false"
  cluster_name                         = "${local.cluster_name}"
  subnets                              = ["${data.terraform_remote_state.vpc.private_subnets}"]
  tags                                 = "${local.tags}"
  vpc_id                               = "${data.terraform_remote_state.vpc.vpc_id}"
  worker_groups                        = "${local.worker_groups}"
  worker_groups_launch_template        = "${local.worker_groups_launch_template}"
  worker_group_count                   = "1"
  worker_group_launch_template_count   = "1"
  worker_additional_security_group_ids = ["${aws_security_group.all_worker_mgmt.id}"]
  map_roles                            = "${var.map_roles}"
  map_roles_count                      = "${var.map_roles_count}"
  map_users                            = "${var.map_users}"
  map_users_count                      = "${var.map_users_count}"
  map_accounts                         = "${var.map_accounts}"
  map_accounts_count                   = "${var.map_accounts_count}"
}
