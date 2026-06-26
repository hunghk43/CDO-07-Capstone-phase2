variable "aws_region" {
  description = "AWS region for bootstrap resources."
  type        = string
  default     = "ap-southeast-1"
}

variable "aws_profile" {
  description = "Local AWS CLI profile used when running bootstrap Terraform from a workstation."
  type        = string
  default     = null
}

variable "project" {
  description = "Project prefix used for named AWS resources."
  type        = string
  default     = "tf4-cdo07"
}

variable "environment" {
  description = "Bootstrap environment label."
  type        = string
  default     = "bootstrap"
}

variable "state_bucket_name" {
  description = "Globally unique S3 bucket name for Terraform remote state."
  type        = string
  default     = "tf4-cdo07-tf-state"
}

variable "github_repository" {
  description = "GitHub repository allowed to assume CI/CD roles, in owner/repo format."
  type        = string
  default     = "CDO-07/CDO-07-Capstone-phase2"
}

variable "github_allowed_branches" {
  description = "Branches allowed by the GitHub OIDC trust policy."
  type        = list(string)
  default     = ["develop", "main"]
}

variable "github_allowed_environments" {
  description = "GitHub Environments allowed to assume the deploy role."
  type        = list(string)
  default     = ["staging", "prod"]
}

variable "terraform_state_prefix" {
  description = "S3 key prefix used by Terraform state files."
  type        = string
  default     = "tf4-cdo07"
}

variable "ecr_image_retention_count" {
  description = "Number of tagged ECR images to retain per repository."
  type        = number
  default     = 20
}
