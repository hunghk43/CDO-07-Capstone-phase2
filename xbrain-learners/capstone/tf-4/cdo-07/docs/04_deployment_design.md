# Deployment & CI/CD Design - Task Force 4 · CDO-07

<!-- Doc owner: CDO-07
     Status: Updated W12 T4 - aligned with ADOT/AMP architecture
     Word target: 1200-2000 từ
     Last updated: 2026-06-26 -->

Tài liệu này mô tả cách cấp phát và phát hành platform TF4 Foresight Lens trên AWS bằng Terraform và GitHub Actions.

Kiến trúc runtime là source of truth theo [`02_infra_design.md`](02_infra_design.md):

```text
k6 Load Generator
  → Application Load Balancer
  → ECS Fargate Mock Services + ADOT sidecars
  → Amazon Managed Prometheus (AMP)
  → EventBridge + Lambda Window Feeder
  → ECS Fargate AI Engine
  → S3 Audit/Baseline + SNS/Slack + Amazon Managed Grafana
```

CI/CD chỉ triển khai kiến trúc này, không thay đổi data flow. Kiến trúc hiện tại dùng ADOT + AMP cho telemetry/time-series, không dùng Kinesis Data Streams hoặc Amazon Timestream.

## 1. IaC strategy

### 1.1 Tool choice

- **IaC tool**: Terraform HCL.
- **AWS region**: `us-east-1`.
- **Terraform version**: `>= 1.10, < 2.0` để dùng S3 native state locking.
- **State backend**: S3 bucket `tf4-cdo07-tf-state`, bật versioning, block public access, SSE-KMS và `use_lockfile = true`.
- **Authentication**: GitHub Actions assume AWS role qua OIDC, không dùng static AWS access keys.

Terraform được chọn vì AWS provider hỗ trợ tốt ECS Fargate, ALB, AMP, ADOT-related IAM, EventBridge, Lambda, S3, CloudWatch, SNS, Managed Grafana và GitHub OIDC. `terraform plan` cũng tạo review gate rõ ràng trước khi thay đổi shared AWS account.

Bootstrap Terraform tạo một lần:

- S3 remote state bucket và KMS key.
- GitHub OIDC provider.
- `AWS_PLAN_ROLE_ARN` cho `terraform plan`.
- `AWS_DEPLOY_ROLE_ARN` cho `terraform apply` và ECS deployment.
- ECR repositories cho container images.

### 1.2 Module structure

Target module structure:

```text
infra/
├── bootstrap/                    # State bucket, KMS key, GitHub OIDC roles, ECR
├── modules/
│   ├── networking/               # VPC, public/private subnets, SG, VPC endpoints
│   ├── ai_hosting/               # ALB + ECS Fargate AI Engine
│   ├── telemetry/                # ADOT collector config, AMP remote-write IAM
│   ├── observability/            # AMP, Managed Grafana, CloudWatch alarms
│   ├── scheduling/               # EventBridge rules, Lambda Window Feeder/CB
│   └── audit/                    # S3 baseline/audit buckets and lifecycle
├── environments/
│   ├── staging/
│   └── prod/
└── scripts/
    ├── deploy-ecs-rolling.sh
    ├── deploy-codedeploy-bluegreen.sh
    └── smoke-test.sh
```

### 1.3 State management và deployment waves

Mỗi environment dùng state key riêng:

```text
tf4-cdo07/staging/terraform.tfstate
tf4-cdo07/prod/terraform.tfstate
```

Deployment order:

1. Networking, security groups và VPC endpoints.
2. S3 baseline/audit, KMS và IAM boundaries.
3. AMP workspace, ADOT collector config và CloudWatch log groups.
4. ECS Fargate cluster, mock services và AI Engine service.
5. ALB listener/target group và health checks.
6. EventBridge + Lambda Window Feeder / Cost Circuit Breaker.
7. Managed Grafana, SNS/Slack notification và CloudWatch alarms.

## 2. CI/CD pipeline

### 2.1 Pull request CI

```text
PR opened/updated
  → build-test.yml
  → security-scan.yml
  → terraform-plan.yml
  → review + approval
  → merge
```

`build-test.yml` detect service source và chạy test theo ngôn ngữ:

- Node.js: install dependencies, chạy `npm test --if-present`.
- Python: install requirements/pyproject, chạy `pytest` nếu có `tests/`.
- Go: chạy `go test ./...`.
- Docker: build image nếu service có `Dockerfile`.

Image được tag bằng full Git SHA. Không deploy mutable tag như `latest`.

### 2.2 GitHub Actions workflows

Repo hiện dùng các workflow sau:

| Workflow | Trigger | Trách nhiệm | Gate |
|---|---|---|---|
| `build-test.yml` | PR; push `develop`, `main` | Test service source và build Docker image nếu có | Build/test pass |
| `security-scan.yml` | PR; push `develop`, `main` | Gitleaks, Trivy filesystem scan, Checkov Terraform scan | Không có secret; không có HIGH/CRITICAL issue chưa xử lý; Checkov pass |
| `terraform-plan.yml` | PR vào `develop`/`main`; manual dispatch | `fmt`, `init`, `validate`, `plan`, ghi summary | Plan review trước merge |
| `deploy-staging.yml` | Push vào `develop`; manual dispatch | Assume deploy role, login ECR, build/push image, `terraform apply` staging, deploy ECS, smoke test | Deploy success + smoke test |
| `deploy-prod.yml` | Manual dispatch | Deploy full Git SHA đã pass staging, yêu cầu confirm `DEPLOY_PROD` và Environment approval | Đúng immutable digest + prod approval |
| `drift-detection.yml` | Cron hằng ngày; manual dispatch | `terraform plan -detailed-exitcode` cho staging/prod/bootstrap | Exit 0 no drift; exit 2 warning; exit 1 fail |
| `slack-notifications.yml` | Push, PR opened/reopened/ready, PR merged | Gửi Slack notification qua `SLACK_WEBHOOK_URL` | Webhook gửi thành công |

Không dùng workflow chung tên `deploy.yml` và không dùng `workflow_run` làm production gate. Production chỉ chạy manual để tránh deploy nhầm.

### 2.3 Branch strategy

- `feat/<scope>`: nhánh feature/docs/infra.
- PR `feat/*` → `develop`: CI pass và ít nhất một approval.
- `develop`: source of truth cho staging, merge vào đây trigger staging deployment.
- PR `develop` → `main`: promotion sang production-ready baseline.
- `main`: default branch; production/demo deploy bằng manual dispatch từ Git SHA đã pass staging.

## 3. GitOps model

CDO-07 dùng **GitHub Actions + Terraform + ECS Fargate** làm lightweight GitOps. Không dùng Kubernetes GitOps controller vì platform chạy trên ECS Fargate.

Ranh giới ownership:

- Terraform sở hữu networking, IAM, AMP, S3, EventBridge/Lambda, CloudWatch, Grafana, ECS service baseline và ALB.
- Release workflow sở hữu image SHA, task definition revision và ECS service rollout.
- Không dùng image tag mutable trong Terraform release path.

Với ECS services được release ngoài Terraform, Terraform resource nên ignore task definition drift do deployment workflow tạo:

```hcl
lifecycle {
  ignore_changes = [task_definition]
}
```

### 3.1 Drift detection

`drift-detection.yml` chạy hằng ngày:

```text
terraform plan -detailed-exitcode
0 → không có drift
1 → plan lỗi
2 → có drift hoặc infra chưa apply
```

Workflow hiện ghi kết quả vào GitHub Actions summary. Drift không được auto-apply; mọi reconcile phải đi qua PR hoặc change request rõ ràng. Slack alert cho drift là bước mở rộng sau khi nối SNS/Slack vào workflow này.

## 4. Deployment strategy

### 4.1 AI Engine

AI Engine là HTTP service chạy trên ECS Fargate sau Application Load Balancer. Deployment mặc định dùng ECS rolling update:

- `minimumHealthyPercent = 100`.
- `maximumPercent = 200`.
- ECS deployment circuit breaker enabled.
- ALB health check gọi `/health`.
- CloudWatch alarms theo dõi ALB 5xx, target health, p99 latency và task health.

Nếu production/demo cần canary hoặc blue/green, có thể dùng CodeDeploy với hai target groups. Đây là deployment enhancement, không phải data-flow requirement.

### 4.2 Mock Services + ADOT sidecars

Mock services sinh synthetic workload cho 3 tenants (`payment-gateway`, `ledger-service`, `fraud-detection`). Mỗi ECS task chạy ADOT sidecar để collect metrics và remote-write vào Amazon Managed Prometheus.

Deployment dùng ECS rolling update. Health gate:

- ECS task đạt steady state.
- ADOT collector không có remote-write error.
- AMP ingestion/query health ổn định.
- CloudWatch logs không có error spike.

### 4.3 EventBridge + Lambda Window Feeder

EventBridge chạy chu kỳ 5 phút để kích hoạt Lambda Window Feeder.

Window Feeder flow:

1. Query metric window từ AMP bằng PromQL.
2. Gọi AI Engine `/v1/predict`.
3. Ghi prediction audit vào S3.
4. Gửi notification qua SNS/Slack nếu phát hiện drift/capacity risk.
5. Nếu AI timeout hoặc trả lỗi nhiều lần, kích hoạt fail-open static thresholds.

Rollback Window Feeder bằng PR revert hoặc Lambda version/alias rollback. Không rollback state file thủ công.

## 5. Environment separation

| Environment | Branch/trigger | Mục đích | Deployment |
|---|---|---|---|
| Staging | Merge/push vào `develop` | Integration AI-CDO, load test, curveball | Auto deploy sau CI pass |
| Production/demo | Manual dispatch từ Git SHA đã pass staging | Demo production-ready baseline | GitHub Environment approval + confirm string |

Mỗi environment có state key, prefix, tag và ECS cluster riêng trong cùng AWS account.

## 6. Secrets and variables

GitHub Actions xác thực AWS bằng OIDC:

```yaml
permissions:
  id-token: write
  contents: read
```

Repository variables:

| Variable | Mục đích |
|---|---|
| `AWS_ACCOUNT_ID` | AWS account triển khai |
| `AWS_PLAN_ROLE_ARN` | Role cho Terraform plan |
| `AWS_DEPLOY_ROLE_ARN` | Role cho Terraform apply/ECS deploy |
| `STAGING_BASE_URL` | Base URL cho smoke test staging |
| `PROD_BASE_URL` | Base URL cho smoke test prod/demo |

Repository secrets:

| Secret | Mục đích |
|---|---|
| `SLACK_WEBHOOK_URL` | Slack incoming webhook cho push/PR/merge notification |

Không lưu AWS static access key trong GitHub Secrets. Application secrets nằm trong AWS Secrets Manager hoặc SSM Parameter Store; pipeline chỉ truyền ARN hoặc parameter name.

## 7. Service onboarding deployment

Onboarding service mới vào telemetry/baseline pipeline:

1. Đăng ký `service_id`, tenant label, metric whitelist và alert policy.
2. Cập nhật ADOT collector config hoặc service instrumentation.
3. Deploy service/mock service qua ECS Fargate.
4. ADOT sidecar remote-write metrics vào AMP.
5. Smoke test PromQL query theo `service_id`.
6. Provision Grafana dashboard filter/annotation cho service.
7. AI team trigger baseline training khi đủ dữ liệu lịch sử.

Metric sai schema hoặc label cardinality vượt chuẩn được log/drop theo ADOT collector policy và cảnh báo qua CloudWatch/SNS.

## 8. Observability and smoke test

| Thành phần | Công cụ | Evidence |
|---|---|---|
| Time-series source | Amazon Managed Prometheus | Samples ingested, PromQL query result, cardinality |
| Collection | ADOT sidecar | Remote-write success/error, collector logs |
| Dashboard | Amazon Managed Grafana | Metrics, prediction, recommendation, annotation |
| ECS logs | CloudWatch Logs | Structured JSON, correlation ID, retention 14 ngày |
| Serving monitoring | CloudWatch + ALB | ALB 5xx, p50/p99 latency, task health |
| Audit | S3 SSE-KMS | Prediction audit, baseline artifacts |
| Scheduling | EventBridge + Lambda | Window feeder invocation, retry, DLQ |
| Notification | SNS/Slack | Deploy, rollback, alarm, PR/merge notification |

Smoke test sau deployment cần chứng minh:

1. Mock service phát sinh telemetry fixture.
2. ADOT sidecar remote-write metric vào AMP.
3. PromQL query trả được metric theo `service_id`.
4. Lambda Window Feeder gọi được AI Engine `/v1/predict`.
5. Prediction audit object xuất hiện trong S3.
6. AI `503` hoặc timeout kích hoạt static-threshold fallback.

## 9. Open questions

- [ ] AI Deployment Contract đã khóa ECR ownership, container port, `/health`, CPU/memory và task role chưa?
- [ ] ADOT collector config, Prometheus labels và cardinality limit đã được khóa trong Telemetry Contract chưa?
- [ ] `STAGING_BASE_URL` và `PROD_BASE_URL` đã được cấu hình để smoke test không skip chưa?
- [ ] Drift detection có cần gửi Slack alert ngay trong W12 hay chỉ giữ GitHub Actions summary?
- [ ] Runtime Terraform roots `staging` và `prod` đã đủ module networking, ai_hosting, telemetry, scheduling, audit và observability chưa?

## Related documents

- [`02_infra_design.md`](02_infra_design.md) - Runtime architecture và component ownership.
- [`03_security_design.md`](03_security_design.md) - IAM, network, encryption và audit controls.
- [`05_cost_analysis.md`](05_cost_analysis.md) - Cost model ADOT/AMP.
- [`08_adrs.md`](08_adrs.md) - Architecture decision records.
- [Amazon Managed Service for Prometheus](https://docs.aws.amazon.com/prometheus/latest/userguide/what-is-Amazon-Managed-Service-Prometheus.html)
- [AWS Distro for OpenTelemetry](https://aws-otel.github.io/)
- [Terraform S3 backend](https://developer.hashicorp.com/terraform/language/backend/s3)
- [GitHub Actions OIDC với AWS](https://docs.github.com/en/actions/how-tos/secure-your-work/security-harden-deployments/oidc-in-aws)
