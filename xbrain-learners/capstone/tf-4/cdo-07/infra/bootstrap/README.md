# Bootstrap Terraform - TF4 CDO-07

Bootstrap tạo các tài nguyên nền tảng dùng chung cho CI/CD:

- S3 bucket lưu Terraform state, có versioning, block public access, SSE-KMS và bucket policy chặn HTTP không TLS.
- KMS key `alias/tf4-cdo07-bootstrap-bootstrap`.
- GitHub Actions OIDC provider `https://token.actions.githubusercontent.com`.
- IAM role cho plan/drift detection: `tf4-cdo07-github-plan-role`.
- IAM role cho deploy/apply: `tf4-cdo07-github-deploy-role`.
- ECR repositories:
  - `tf4-cdo07-ingest-service`
  - `tf4-cdo07-ingest-worker`
  - `tf4-cdo07-ai-serving`

## Chạy bootstrap

Bootstrap nên chạy bằng AWS credential admin tạm thời trên máy local hoặc CloudShell. Không chạy bằng GitHub Actions lần đầu, vì OIDC roles chưa tồn tại.

```bash
cd xbrain-learners/capstone/tf-4/cdo-07/infra/bootstrap
cp terraform.tfvars.example terraform.tfvars
```

Sửa `state_bucket_name` thành bucket name global-unique, ví dụ:

```hcl
state_bucket_name = "tf4-cdo07-tf-state-123456789012"
```

Sau đó chạy:

```bash
terraform init
terraform fmt -recursive
terraform validate
terraform plan
terraform apply
```

## GitHub variables cần set sau khi apply

Lấy output:

```bash
terraform output github_plan_role_arn
terraform output github_deploy_role_arn
terraform output ecr_repository_urls
```

Set GitHub repository hoặc organization variables:

| Variable | Value |
|---|---|
| `AWS_ACCOUNT_ID` | AWS account ID |
| `AWS_PLAN_ROLE_ARN` | output `github_plan_role_arn` |
| `AWS_DEPLOY_ROLE_ARN` | output `github_deploy_role_arn` |

## Backend config cho environment roots

Các Terraform root trong `infra/environments/*` nên dùng:

```hcl
terraform {
  backend "s3" {
    bucket       = "tf4-cdo07-tf-state-123456789012"
    key          = "tf4-cdo07/staging/terraform.tfstate"
    region       = "ap-southeast-1"
    encrypt      = true
    kms_key_id   = "<bootstrap-kms-key-arn>"
    use_lockfile = true
  }
}
```

Đổi `key` theo từng environment:

- `tf4-cdo07/sandbox/terraform.tfstate`
- `tf4-cdo07/staging/terraform.tfstate`
- `tf4-cdo07/prod/terraform.tfstate`

## Ghi chú quyền

- Plan role cho phép đọc resource để `terraform plan` và ghi/xóa `.tflock`.
- Deploy role có quyền rộng hơn để apply hạ tầng capstone, nhưng IAM management được scope theo prefix `tf4-cdo07-*`.
- Trust policy giới hạn GitHub repo `CDO-07/CDO-07-Capstone-phase2`, branch `develop`/`main` và GitHub Environments `staging`/`prod`; plan role cho phép thêm PR subject để chạy plan trên pull request.
