locals {
  name_prefix = "${var.project}-${var.environment}"

  github_subjects = [
    for branch in var.github_allowed_branches :
    "repo:${var.github_repository}:ref:refs/heads/${branch}"
  ]

  github_environment_subjects = [
    for environment in var.github_allowed_environments :
    "repo:${var.github_repository}:environment:${environment}"
  ]

  ecr_repositories = toset([
    "ingest-service",
    "ingest-worker",
    "ai-serving",
  ])

  common_tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "Terraform"
    Owner       = "CDO-07"
    TaskForce   = "TF4"
  }
}
