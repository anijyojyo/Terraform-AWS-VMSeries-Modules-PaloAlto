data "aws_caller_identity" "current" {}

################
# S3 Buckets and Contents
################

resource "aws_s3_bucket" "this" {
  bucket        = var.lambda_s3_bucket
  force_destroy = true
  tags          = merge(var.tags, { Name = var.lambda_s3_bucket })
}

resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "example" {
  bucket = aws_s3_bucket.this.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket = aws_s3_bucket.this.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_object" "this" {
  bucket = aws_s3_bucket.this.id
  key    = var.lambda_file_name
  acl    = "private"
  source = "${var.lambda_file_location}/${var.lambda_file_name}"
  etag   = filemd5("${var.lambda_file_location}/${var.lambda_file_name}")
}


################
# IAM Resources
################

data "aws_caller_identity" "this" {}

# Lookup information about the current AWS partition in which Terraform is working (e.g. `aws`, `aws-us-gov`, `aws-cn`)
data "aws_partition" "this" {}

resource "aws_iam_role" "lambda_exec" {
  name = "${var.prefix_name_tag}-lambda-exec"
  path = "/"
  tags = var.tags

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF
}

resource "aws_iam_role_policy_attachment" "test_attach" {
  role       = aws_iam_role.lambda_exec.id
  policy_arn = "arn:${data.aws_partition.this.partition}:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}


resource "aws_iam_role_policy" "lambda_exec" {
  name = "${var.prefix_name_tag}-lambda-exec"
  role = aws_iam_role.lambda_exec.id

  policy = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Action": [
                "ec2:DescribeRouteTables",
                "ec2:DescribeSecurityGroups",
                "ec2:DescribeSubnets",
                "ec2:DescribeVpcs"
            ],
            "Resource": [
                "*"
            ],
            "Effect": "Allow"
        },
        {
            "Action": [
                "ec2:CreateRoute",
                "ec2:DeleteRoute",
                "ec2:ReplaceRoute"
            ],
            "Resource": [
                "arn:${data.aws_partition.this.partition}:ec2:${var.region}:${data.aws_caller_identity.this.account_id}:route-table/*"
            ],
            "Effect": "Allow"
        },
        {
            "Action": [
                "ec2:AssociateRouteTable",
            ],
            "Resource": [
                "arn:${data.aws_partition.this.partition}:ec2:${var.region}:${data.aws_caller_identity.this.account_id}:route-table/*",
                "arn:${data.aws_partition.this.partition}:ec2:${var.region}:${data.aws_caller_identity.this.account_id}:internet-gateway/*"
                "arn:${data.aws_partition.this.partition}:ec2:${var.region}:${data.aws_caller_identity.this.account_id}:subnet/*"
                "arn:${data.aws_partition.this.partition}:ec2:${var.region}:${data.aws_caller_identity.this.account_id}:vpn-gateway/*"
            ],
            "Effect": "Allow"
        }         
    ]
}
EOF
}


# "logs:*",

resource "aws_lambda_function" "rt_failover" {
  function_name = "${var.prefix_name_tag}-rt-failover"
  handler       = "crosszone_ha_instance_id.lambda_handler"
  role          = aws_iam_role.lambda_exec.arn
  s3_bucket     = aws_s3_bucket.this.id
  s3_key        = aws_s3_object.this.id
  #source_code_hash = filebase64sha256("crosszone_ha_instance_id.zip")
  runtime                        = "python3.8"
  timeout                        = "30"
  description                    = "Used for updating VPC RTs during PAN failover"
  reserved_concurrent_executions = var.reserved_concurrent_executions
  tracing_config {
    mode = "Active"
  }
  vpc_config {
    subnet_ids         = [var.subnet_state["${var.prefix_name_tag}-lambda-1a"], var.subnet_state["${var.prefix_name_tag}-lambda-1b"]]
    security_group_ids = [var.sg_state["${var.prefix_name_tag}-pan-mgmt"]]
  }
}


resource "aws_vpc_endpoint" "api" {
  vpc_id            = var.vpc_id
  service_name      = "com.amazonaws.${var.region}.execute-api"
  vpc_endpoint_type = "Interface"

  subnet_ids         = [var.subnet_state["${var.prefix_name_tag}-lambda-1a"], var.subnet_state["${var.prefix_name_tag}-lambda-1b"]]
  security_group_ids = [var.sg_state["${var.prefix_name_tag}-pan-mgmt"]]

  private_dns_enabled = true
  # policy = todo

  tags = merge(var.tags, { Name = "${var.prefix_name_tag}-apiendpoint" })
}

resource "aws_api_gateway_rest_api" "pan_failover" {
  name        = "${var.prefix_name_tag}-API-GW"
  description = "Used to trigger lambda for PAN cross zone failover"

  endpoint_configuration {
    types            = ["PRIVATE"]
    vpc_endpoint_ids = [aws_vpc_endpoint.api.id]
  }

  policy = <<POLICY
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": "*",
            "Action": "execute-api:Invoke",
            "Resource": "arn:${data.aws_partition.this.partition}:execute-api:${var.region}:${data.aws_caller_identity.current.account_id}:*/*"
        },
        {
            "Effect": "Deny",
            "Principal": "*",
            "Action": "execute-api:Invoke",
            "Resource": "arn:${data.aws_partition.this.partition}:execute-api:${var.region}:${data.aws_caller_identity.current.account_id}:*/*",
            "Condition": {
                "StringNotEquals": {
                    "aws:SourceVpce": "${aws_vpc_endpoint.api.id}"
                }
            }
        }
    ]
}
POLICY

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_resource" "pan_failover" {
  rest_api_id = aws_api_gateway_rest_api.pan_failover.id
  parent_id   = aws_api_gateway_rest_api.pan_failover.root_resource_id
  path_part   = "xzoneha"
}

resource "aws_api_gateway_method" "pan_failover" {
  rest_api_id      = aws_api_gateway_rest_api.pan_failover.id
  resource_id      = aws_api_gateway_resource.pan_failover.id
  http_method      = "POST"
  authorization    = "NONE"
  api_key_required = true

  request_parameters = {
    "method.request.querystring.vpc_id"          = false
    "method.request.querystring.good_instance"   = false
    "method.request.querystring.failed_instance" = false
  }

}


resource "aws_api_gateway_method_response" "pan_failover" {
  rest_api_id = aws_api_gateway_rest_api.pan_failover.id
  resource_id = aws_api_gateway_resource.pan_failover.id
  http_method = aws_api_gateway_method.pan_failover.http_method
  status_code = "200"
  response_models = {
    "application/json" = "Empty"
  }
}

resource "aws_api_gateway_integration" "pan_failover" {
  rest_api_id             = aws_api_gateway_rest_api.pan_failover.id
  resource_id             = aws_api_gateway_resource.pan_failover.id
  http_method             = "POST"
  integration_http_method = "POST"
  type                    = "AWS"
  passthrough_behavior    = "WHEN_NO_TEMPLATES"
  uri                     = "arn:${data.aws_partition.this.partition}:apigateway:${var.region}:lambda:path/2015-03-31/functions/${aws_lambda_function.rt_failover.arn}/invocations"
  request_templates = {
    "application/json" = <<REQUEST_TEMPLATE
{
  "vpc_id" : "$input.params('vpc_id')",
  "good_instance" : "$input.params('good_instance')",
  "failed_instance" : "$input.params('failed_instance')"
}
REQUEST_TEMPLATE
  }
}

resource "aws_api_gateway_integration_response" "pan_failover" {
  depends_on = [aws_api_gateway_integration.pan_failover]

  rest_api_id = aws_api_gateway_rest_api.pan_failover.id
  resource_id = aws_api_gateway_resource.pan_failover.id
  http_method = "POST"
  status_code = "200"
}

resource "aws_api_gateway_deployment" "pan_failover" {
  depends_on = [aws_api_gateway_integration.pan_failover, aws_api_gateway_integration_response.pan_failover,
    aws_api_gateway_method_response.pan_failover, aws_api_gateway_method.pan_failover, aws_api_gateway_resource.pan_failover,
  aws_api_gateway_rest_api.pan_failover, aws_lambda_function.rt_failover]

  rest_api_id = aws_api_gateway_rest_api.pan_failover.id
  stage_name  = "prod"

  lifecycle {
    create_before_destroy = true
  }
}


resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.rt_failover.function_name
  principal     = "apigateway.amazonaws.com"

  # The "/*/*" portion grants access from any method on any resource
  # within the API Gateway REST API.
  source_arn = "${aws_api_gateway_rest_api.pan_failover.execution_arn}/*"
}

