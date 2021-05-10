provider "aws" {
    version = "3.38.0"
    region = var.region
}
////////////////////////////////////////////////////////////////////////////////////  Network  ////////////////////////////////////////////////////////////////////////////////////////////////
resource "aws_vpc" "checkpoint"{
    cidr_block = "10.0.0.0/16"

    tags = {
        Name = "checkpoint VPC"
    }
}

resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.checkpoint.id
}

resource "aws_subnet" "main"{
    vpc_id = aws_vpc.checkpoint.id
    cidr_block = "10.0.0.0/16"
    tags = {
        Name = "main subnet"
    }
}
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////  ELK   ////////////////////////////////////////////////////////////////////////////////////////////////
# resource "aws_network_interface" "nic_test"{
#     subnet_id = aws_subnet.main.id
# }

resource "aws_eip" "logstash_eip" {
  instance = aws_instance.logsash.id
#   network_interface = aws_network_interface.nic_test.id
  vpc      = true
}

# resource "tls_private_key" "example" {
#   algorithm = "RSA"
#   rsa_bits  = 4096
# }

# resource "aws_key_pair" "generated_key" {
#   key_name   = "test"
#   public_key = tls_private_key.example.public_key_openssh
# }

resource "aws_instance" "logsash" {
    ami = var.ami
    instance_type = var.vm_instance_type
    subnet_id = aws_subnet.main.id
    # key_name = aws_key_pair.generated_key.key_name
    tags = {
        Name = "logstash"
    }
    # network_interface {
    #     network_interface_id = aws_network_interface.nic_test.id
    #     device_index         = 0
    # }
    iam_instance_profile = aws_iam_instance_profile.test_profile.name
    user_data = <<-EOF
        #!/bin/bash
        sudo apt-get install default-jre -y && \
        wget -qO - https://artifacts.elastic.co/GPG-KEY-elasticsearch | sudo apt-key add - && \
        sudo apt-get install apt-transport-https -y && \
        echo "deb https://artifacts.elastic.co/packages/6.x/apt stable main" | sudo tee -a /etc/apt/sources.list.d/elastic-6.x.list && \
        sleep 1 && \
        sudo apt-get update -y && sudo apt-get install logstash -y && \
        cat > /etc/logstash/conf.d/sqs-input.conf <<EOT
        input { sqs {
        queue => "terraform-example-queue"
        region => "us-east-2"
        codec => "plain"
        }}
        output {
        elasticsearch {
            hosts => ["https://search-testdomain-myasnnnzmzffepeoyohuhsegcm.us-east-2.es.amazonaws.com:443"]
            index => "sqs-%%{+YYYY.MM}"
        }
        }
        EOT

        systemctl restart logstash 
        EOF


#     connection{
#         type = "ssh"
#         host = aws_eip.logstash_eip.public_ip
#         user = "ubuntu"
#         private_key = tls_private_key.example.private_key_pem

#     }
    
    #   user_data=file("script.sh")
#     provisioner "file" {
#        source      = "script.sh"
#         destination = "/tmp/script.sh"
#     }

#   provisioner "remote-exec" {
#     inline = [
#       "chmod +x /tmp/script.sh",
#       "/tmp/script.sh",
#     ]
#   }

}

resource "aws_elasticsearch_domain" "testdomain" {
  domain_name           = "testdomain"
  elasticsearch_version = "7.10"
  ebs_options {
    ebs_enabled = "true"
    volume_size = "25"
  }

  cluster_config {
    instance_type = "t2.small.elasticsearch"
  }

    access_policies = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": "*"
      },
      "Action": "es:*",
      "Resource": "arn:aws:es:us-east-2:383481165814:domain/testdomain/*",
      "Condition": {
        "IpAddress": {
          "aws:SourceIp": ["0.0.0.0/1","128.0.0.0/1"]
        }
      }
    }
  ]
}
POLICY
  tags = {
    Domain = "testdomain"
  }
}
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
//////////////////////////////////////////////////////////////////////////////////////////////// SQS ////////////////////////////////////////////////////////////////////////////////////////////////
resource "aws_sqs_queue" "terraform_queue" {
  name = "terraform-example-queue"

  tags = {
    Name = "testqueue"
  }
}

resource "aws_sqs_queue_policy" "test" {
  queue_url = aws_sqs_queue.terraform_queue.id

  policy = <<POLICY
{
  "Version": "2012-10-17",
  "Id": "sqspolicy",
  "Statement": [
    {
      "Sid": "First",
      "Effect": "Allow",
      "Principal": "*",
      "Action": "sqs:SendMessage",
      "Resource": "${aws_sqs_queue.terraform_queue.arn}",
      "Condition": {
        "ArnEquals": {
          "aws:SourceArn": "${aws_instance.logsash.arn}"
        }
      }
    }
  ]
}
POLICY
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
/////////////////////////////////////////////////////////////////////////////////////////// IAM Roles /////////////////////////////////////////////////////////////////////////////////////////////
resource "aws_iam_role" "role" {
  name = "test_role"
  assume_role_policy = jsonencode({
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Sid    = ""
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      },
    ]
  })
   tags = {
      tag-key = "tag-value"
  }
}
resource "aws_iam_instance_profile" "test_profile" {
  name = "test_profile"
  role = aws_iam_role.role.name
}


resource "aws_iam_role_policy" "policy" {
  name = "test_policy"
  role = aws_iam_role.role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement: [
            {
            Action: [
                "sqs:ChangeMessageVisibility",
                "sqs:ChangeMessageVisibilityBatch",
                "sqs:DeleteMessage",
                "sqs:DeleteMessageBatch",
                "sqs:GetQueueAttributes",
                "sqs:GetQueueUrl",
                "sqs:ListQueues",
                "sqs:ReceiveMessage"
            ],
            Effect: "Allow",
            Resource: [
                "${aws_sqs_queue.terraform_queue.arn}"
            ]
            }
        ]
    })
}
