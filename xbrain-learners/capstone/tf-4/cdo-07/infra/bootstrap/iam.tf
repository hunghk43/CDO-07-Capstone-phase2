resource "aws_iam_role" "github_plan" {
  name               = "${var.project}-github-plan-role"
  assume_role_policy = data.aws_iam_policy_document.github_oidc_plan_assume_role.json
  description        = "GitHub Actions role for Terraform plan and drift detection."
}

resource "aws_iam_role" "github_deploy" {
  name               = "${var.project}-github-deploy-role"
  assume_role_policy = data.aws_iam_policy_document.github_oidc_deploy_assume_role.json
  description        = "GitHub Actions role for Terraform apply and ECS/ECR deployment."
}

resource "aws_iam_policy" "github_plan" {
  name        = "${var.project}-github-plan-policy"
  description = "Read-only AWS access plus Terraform state lock permissions for plan workflows."
  policy      = data.aws_iam_policy_document.github_plan.json
}

resource "aws_iam_policy" "github_deploy" {
  name        = "${var.project}-github-deploy-policy"
  description = "Scoped deployment permissions for Terraform, ECR, ECS and CodeDeploy."
  policy      = data.aws_iam_policy_document.github_deploy.json
}

resource "aws_iam_role_policy_attachment" "github_plan" {
  role       = aws_iam_role.github_plan.name
  policy_arn = aws_iam_policy.github_plan.arn
}

resource "aws_iam_role_policy_attachment" "github_deploy" {
  role       = aws_iam_role.github_deploy.name
  policy_arn = aws_iam_policy.github_deploy.arn
}

#checkov:skip=CKV_AWS_356:Plan role needs wildcard resources for AWS read-only APIs that do not support resource-level permissions.
data "aws_iam_policy_document" "github_plan" {
  statement {
    sid    = "AllowReadOnlyForPlanning"
    effect = "Allow"

    actions = [
      "acm:Describe*",
      "acm:List*",
      "application-autoscaling:Describe*",
      "cloudwatch:Describe*",
      "cloudwatch:Get*",
      "cloudwatch:List*",
      "codedeploy:Get*",
      "codedeploy:List*",
      "dynamodb:Describe*",
      "dynamodb:List*",
      "ec2:Describe*",
      "ecr:Describe*",
      "ecr:Get*",
      "ecs:Describe*",
      "ecs:List*",
      "elasticloadbalancing:Describe*",
      "events:Describe*",
      "events:List*",
      "iam:Get*",
      "iam:List*",
      "kms:Describe*",
      "kms:Get*",
      "kms:List*",
      "logs:Describe*",
      "logs:Get*",
      "logs:List*",
      "s3:GetBucket*",
      "s3:GetEncryptionConfiguration",
      "s3:GetLifecycleConfiguration",
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:ListBucket",
      "scheduler:Get*",
      "scheduler:List*",
      "sqs:Get*",
      "sqs:List*",
      "ssm:Describe*",
      "ssm:Get*",
      "ssm:List*",
      "timestream:Describe*",
      "timestream:List*",
    ]

    resources = ["*"]
  }

  statement {
    sid    = "AllowTerraformStateLockForPlan"
    effect = "Allow"

    actions = [
      "s3:DeleteObject",
      "s3:GetObject",
      "s3:PutObject",
    ]

    resources = [
      "${aws_s3_bucket.terraform_state.arn}/${var.terraform_state_prefix}/*.tflock",
    ]
  }

  statement {
    sid    = "AllowTerraformStatePrefixList"
    effect = "Allow"

    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.terraform_state.arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["${var.terraform_state_prefix}/*"]
    }
  }
}

#checkov:skip=CKV_AWS_108:Deploy role is scoped by GitHub OIDC trust policy and resource prefixes where AWS supports them; bootstrap/demo services still require broad service actions.
#checkov:skip=CKV_AWS_109:Deploy role can manage tf4-cdo07 IAM roles only; broader service actions are required for Terraform-managed ECS/ALB/SQS/Timestream resources.
#checkov:skip=CKV_AWS_111:Terraform deploy role needs write actions across AWS services during capstone bootstrap; production hardening should split this into per-service roles.
#checkov:skip=CKV_AWS_356:Some Terraform-managed AWS APIs do not support resource-level permissions, so wildcard resources are required for this CI deploy role.
data "aws_iam_policy_document" "github_deploy" {
  statement {
    sid    = "AllowTerraformStateReadWrite"
    effect = "Allow"

    actions = [
      "s3:DeleteObject",
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:PutObject",
    ]

    resources = [
      "${aws_s3_bucket.terraform_state.arn}/${var.terraform_state_prefix}/*",
    ]
  }

  statement {
    sid    = "AllowTerraformStateList"
    effect = "Allow"

    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.terraform_state.arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["${var.terraform_state_prefix}/*"]
    }
  }

  statement {
    sid    = "AllowEcrPushPull"
    effect = "Allow"

    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImages",
      "ecr:DescribeRepositories",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:ListImages",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]

    resources = [for repository in aws_ecr_repository.services : repository.arn]
  }

  statement {
    sid       = "AllowEcrAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "AllowApplicationDeployment"
    effect = "Allow"

    actions = [
      "application-autoscaling:*",
      "cloudwatch:DeleteAlarms",
      "cloudwatch:DescribeAlarms",
      "cloudwatch:PutMetricAlarm",
      "codedeploy:*",
      "dynamodb:*",
      "ec2:CreateTags",
      "ec2:DeleteTags",
      "ec2:Describe*",
      "ecr:*",
      "ecs:*",
      "elasticloadbalancing:*",
      "events:*",
      "logs:*",
      "s3:*",
      "scheduler:*",
      "sns:*",
      "sqs:*",
      "ssm:*",
      "timestream:*",
    ]

    resources = ["*"]
  }

  statement {
    sid    = "AllowScopedIamManagement"
    effect = "Allow"

    actions = [
      "iam:AttachRolePolicy",
      "iam:CreatePolicy",
      "iam:CreatePolicyVersion",
      "iam:CreateRole",
      "iam:DeletePolicy",
      "iam:DeletePolicyVersion",
      "iam:DeleteRole",
      "iam:DeleteRolePolicy",
      "iam:DetachRolePolicy",
      "iam:GetPolicy",
      "iam:GetPolicyVersion",
      "iam:GetRole",
      "iam:GetRolePolicy",
      "iam:ListAttachedRolePolicies",
      "iam:ListPolicyVersions",
      "iam:ListRolePolicies",
      "iam:PassRole",
      "iam:PutRolePolicy",
      "iam:TagRole",
      "iam:UpdateAssumeRolePolicy",
      "iam:UpdateRole",
    ]

    resources = [
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project}-*",
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/${var.project}-*",
    ]
  }
}
