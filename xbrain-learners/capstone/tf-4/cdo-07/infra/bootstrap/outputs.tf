output "terraform_state_bucket" {
  description = "S3 bucket for Terraform remote state."
  value       = aws_s3_bucket.terraform_state.bucket
}

output "terraform_state_kms_key_arn" {
  description = "KMS key ARN used for Terraform state and ECR encryption."
  value       = aws_kms_key.bootstrap.arn
}

output "github_oidc_provider_arn" {
  description = "GitHub Actions OIDC provider ARN."
  value       = aws_iam_openid_connect_provider.github.arn
}

output "github_plan_role_arn" {
  description = "Set this as GitHub variable AWS_PLAN_ROLE_ARN."
  value       = aws_iam_role.github_plan.arn
}

output "github_deploy_role_arn" {
  description = "Set this as GitHub variable AWS_DEPLOY_ROLE_ARN."
  value       = aws_iam_role.github_deploy.arn
}

output "ecr_repository_urls" {
  description = "ECR repository URLs keyed by service name."
  value = {
    for service, repository in aws_ecr_repository.services :
    service => repository.repository_url
  }
}

output "backend_hcl_example" {
  description = "Example backend config for environment roots."
  value       = <<EOT
bucket       = "${aws_s3_bucket.terraform_state.bucket}"
key          = "${var.terraform_state_prefix}/staging/terraform.tfstate"
region       = "${var.aws_region}"
encrypt      = true
kms_key_id   = "${aws_kms_key.bootstrap.arn}"
use_lockfile = true
EOT
}
