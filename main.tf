terraform {
  required_version = ">= 0.12"

  # Saves the state into s3 bucket
  backend "s3" {
    region         = "ap-southeast-2"
    key            = "terraform.tfstate"
    encrypt        = true
  }
}

provider "aws" {
  version                  = "~> 2.41"
  region                   = "ap-southeast-2"
  shared_credentials_file  = "credentials.ini"
}

resource "aws_ebs_encryption_by_default" "encrypt" {
  enabled = true
}

# Use our local generated keys
resource "aws_key_pair" "main" {
  key_name   = "techtestapp-main"
  public_key = file("secret/aws.pub")
}

# Using default vpc and subnet
data "aws_vpc" "main" {
  default     = true
}

data "aws_subnet_ids" "main" {
  vpc_id      = data.aws_vpc.main.id
}

# Firewall/security group
resource "aws_security_group" "main" {
  name        = "TechTestApp ${var.env}"
  description = "TechTestApp security stuff"

  vpc_id      = data.aws_vpc.main.id

  tags = {
    Name = "TechTestApp ${var.env}"
  }

  lifecycle {
    create_before_destroy = true
  }

  # SSH for ec2 instance
  ingress {
      from_port = 22
      to_port = 22
      protocol = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
      description = "ssh in"
  }

  # PORT 80 for load balancer access
  ingress {
      from_port = 80
      to_port = 80
      protocol = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
      description = "http in LB/public"
  }

  # PORT 8080 for private access lb -> instance
  ingress {
      from_port = 8080
      to_port = 8080
      protocol = "tcp"
      cidr_blocks = [data.aws_vpc.main.cidr_block]
      description = "http in"
  }

  # PORT 5432 for private access instance -> rds
  ingress {
      from_port = 5432
      to_port = 5432
      protocol = "tcp"
      cidr_blocks = [data.aws_vpc.main.cidr_block]
      description = "postgres in private"
  }

  # PORT 5432 output for private access
  egress {
      from_port = 5432
      to_port = 5432
      protocol = "tcp"
      cidr_blocks = [data.aws_vpc.main.cidr_block]
      description = "postgres in private"
  }

  # PORT 80 output for access to http internet
  egress {
      from_port = 80
      to_port = 80
      protocol = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
      description = "http out for yum"
  }

  # PORT 443 output for access to https internet
  egress {
      from_port = 443
      to_port = 443
      protocol = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
      description = "http out for yum"
  }

  # PORT 8080 output private access lb -> instance
  egress {
      from_port = 8080
      to_port = 8080
      protocol = "tcp"
      cidr_blocks = [data.aws_vpc.main.cidr_block]
      description = "http out for lb from nginx"
  }
}

# Fetch AMI reference generated by packer
data "aws_ami" "main" {
  most_recent      = true
  owners           = ["self"]

  filter {
    name           = "tag:TechTestApp"
    values         = ["App"]
  }
}

# Template for launching multiple app instances
resource "aws_launch_template" "app" {
  depends_on                = [null_resource.local-conf-file]
  name_prefix               = "app"
  image_id                  = data.aws_ami.main.id
  instance_type             = "m4.xlarge"

  key_name                  = aws_key_pair.main.key_name
  user_data                 = base64encode(data.template_file.entrypoint.rendered)

  network_interfaces {
    associate_public_ip_address = true
    delete_on_termination       = true
    security_groups             = [aws_security_group.main.id]
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Templating the init file which will be executed once app instances are booted
data "template_file" "entrypoint" {
  template = file("template_init.sh")

  vars = {
    databaseusername  = var.dbusername
    databasepassword  = var.dbpassword

    dbname            = "${var.env}techtestappdb"
    dbhost            = aws_db_instance.main.address
    dbport            = aws_db_instance.main.port
  }
}

# Scaling group for the app instances
resource "aws_autoscaling_group" "app" {
  name                = "techtestapp-${aws_launch_template.app.latest_version}"
  desired_capacity    = var.instance_count_min
  max_size            = var.instance_count_max
  min_size            = var.instance_count_min
  vpc_zone_identifier = [sort(data.aws_subnet_ids.main.ids)[0]]
  load_balancers      = [aws_elb.techtestapp-elb.name]

  launch_template {
    id      = aws_launch_template.app.id
    version = aws_launch_template.app.latest_version
  }

  tag {
    key                 = "Name"
    value               = "TechTestApp Node ${var.env}"
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Load balancer
resource "aws_elb" "techtestapp-elb" {
  name = "${var.env}-techtestapp-elb"

  listener {
    instance_port     = 8080
    instance_protocol = "http"
    lb_port           = 80
    lb_protocol       = "http"
  }

  health_check {
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 3
    target              = "HTTP:8080/up/"
    interval            = 5
  }

  security_groups             = [aws_security_group.main.id]
  subnets                     = [sort(data.aws_subnet_ids.main.ids)[0]]

  cross_zone_load_balancing   = false
  idle_timeout                = 400
  connection_draining         = true
  connection_draining_timeout = 400

  tags = {
    Name = "${var.env}-techtestapp-elb"
  }
}

# Spit out the url for the LB
output "load-balancer-url" {
  value = aws_elb.techtestapp-elb.dns_name
}

# Postgresql database with aws rds
# This could be initialised during setup, but for simplicity i've left it in here
resource "aws_db_instance" "main" {
  #final_snapshot_identifier = "${var.env}techtestappdb"
  skip_final_snapshot       = true
  vpc_security_group_ids    = [aws_security_group.main.id]
  allocated_storage         = 20
  storage_type              = "gp2"
  engine                    = "postgres"
  instance_class            = "db.t2.medium"
  #deletion_protection      = true
  name                      = "${var.env}techtestappdb"
  username                  = var.dbusername
  password                  = var.dbpassword
}

# Variables to be read from config.tfvars
variable "env" {
  type = string
  description = "Environment!"
}

variable "dbusername" {
  type = string
  description = "Database username"
}

variable "dbpassword" {
  type = string
  description = "Database password"
}

variable "instance_count_min" {
  type = number
  description = "Scale instances min"
}

variable "instance_count_max" {
  type = number
  description = "Scale instances max"
}

variable "bucket" {
  type = string
  description = "Bucket/Dynamodb names"
}

variable "dynamodb_table" {
  type = string
  description = "Bucket/Dynamodb names"
}