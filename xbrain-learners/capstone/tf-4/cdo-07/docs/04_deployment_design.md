# Deployment & CI/CD Design - Task Force 4 · CDO-07

<!-- Doc owner: CDO-07
     Status: Draft W11 T4
     Word target: 1200-2000 từ
     Last updated: 2026-06-23 -->

Tài liệu này mô tả cách cấp phát và phát hành platform TF4 Foresight Lens trên
AWS. Kiến trúc runtime là source of truth: Kinesis Data Streams → ECS Fargate
Ingestor → Timestream for InfluxDB → ECS Predictor/Orchestrator → AI Engine.
CI/CD chỉ triển khai kiến trúc này, không thay đổi data flow.

## 1. IaC strategy

### 1.1 Tool choice

- **IaC tool**: Terraform HCL.
- **Lý do chọn**: Terraform có AWS provider ổn định, hỗ trợ module hóa tốt cho
  VPC ba tầng, Kinesis, Timestream for InfluxDB, S3 audit, ECS Fargate,
  CodeDeploy và observability; `terraform plan` cho phép review trước khi đổi
  shared AWS account.
- **Terraform version**: `>= 1.10, < 2.0` để sử dụng S3 native state locking.
- **State backend**: S3 bucket `tf4-cdo07-tf-state`, bật versioning, block
  public access, mã hóa SSE-KMS và `use_lockfile = true`.
- **Không dùng database lock riêng**: S3 native lockfile là cơ chế khóa duy
  nhất. IAM role chạy Terraform cần quyền đọc/ghi state object và
  đọc/ghi/xóa file `.tflock`.

State bucket và GitHub OIDC role được tạo một lần qua bootstrap có review.

### 1.2 Module structure

```text
infra/
├── bootstrap/                    # State bucket, KMS key, GitHub OIDC roles
├── modules/
│   ├── networking/               # VPC, public/private subnets, SG, endpoints
│   ├── data/                     # Timestream for InfluxDB, S3 audit
│   ├── streaming/                # Kinesis Data Streams và failure destination
│   ├── ecs/
│   │   ├── ingestor/             # Fargate Ingestor
│   │   ├── orchestrator/         # Scheduled Fargate task definition
│   │   └── ai-engine/            # AI Engine, ALB, 2 target groups
│   ├── deployment/               # ECR, CodeDeploy app/deployment group
│   └── observability/            # CloudWatch, EventBridge, Managed Grafana
├── environments/
│   ├── sandbox/
│   ├── staging/
│   └── prod/                     # Design-only trong capstone
└── scripts/
    ├── smoke-test.sh
    └── register-service.sh
```

### 1.3 State management và deployment waves

Mỗi environment dùng state key riêng:

```text
tf4-cdo07/sandbox/terraform.tfstate
tf4-cdo07/staging/terraform.tfstate
tf4-cdo07/prod/terraform.tfstate
```

Terraform dependency graph triển khai theo thứ tự:

1. Networking và security boundary.
2. Timestream for InfluxDB và S3 audit.
3. Kinesis Data Streams.
4. ECS Fargate Ingestor.
5. Predictor/Orchestrator task definition và EventBridge Scheduler target.
6. AI Engine ECS service theo Deployment Contract.
7. Managed Grafana, CloudWatch alarms và EventBridge schedule.

## 2. CI/CD pipeline

### 2.1 Container workflow

```text
PR opened
  → Build changed container images
  → Unit/Integration Test
  → Gitleaks + Trivy
  → Terraform fmt/validate/plan
  → Review + approval
  → Merge
  → Push immutable images to ECR
  → Terraform apply approved infrastructure changes
  → Register ECS task-definition revision
  → Deploy ECS service
  → Smoke test
```

Image được tag bằng full Git SHA; không deploy tag mutable như `latest`.

`deploy.yml` chỉ chạy qua `workflow_run` sau khi `build-test.yml` thành công,
hoặc được gọi như reusable workflow với image digest truyền trực tiếp. Vì vậy
deploy không thể chạy trước khi artifact tồn tại trong ECR.

### 2.2 Bốn GitHub Actions workflows

| Workflow | Trigger | Trách nhiệm | Quality gate |
|---|---|---|---|
| `build-test.yml` | PR; push `develop`, `main` | Build Ingestor và Orchestrator image; chạy unit/integration test; trusted push mới được push ECR | Build thành công, test pass |
| `security-scan.yml` | Mọi PR | Gitleaks scan Git history; Trivy scan filesystem và image | Không có secret; 0 CRITICAL CVE |
| `terraform-plan.yml` | PR thay đổi `infra/**` | `fmt -check`, `init`, `validate`, `tflint`, Checkov và `plan`; đăng plan summary vào PR | Plan được Tech Lead review |
| `deploy.yml` | `workflow_run` sau build thành công; manual/approved `main` | Nhận image digest, apply infra change, đăng ký task revision, deploy đúng strategy, chạy smoke test | Artifact tồn tại, deployment success, smoke test pass |

Build matrix chỉ build service có source thay đổi. AI Engine image do nhóm AI
sở hữu; CDO consume ECR URI/digest trong Deployment Contract.

### 2.3 Branch strategy

- `feature/<jira-id>-<description>`: nhánh làm việc.
- PR `feature/*` → `develop`: CI pass và ít nhất một approval.
- `develop`: source of truth của staging; merge thành công sẽ deploy staging.
- PR `develop` → `main`: cần Tech Lead và GitHub Environment approval.
- `main`: production-ready configuration; production design-only trong
  capstone, demo có thể manual-dispatch artifact đã pass staging.

## 3. GitOps

CDO-07 dùng **GitHub Actions + Terraform + CodeDeploy** làm lightweight GitOps.
Không bổ sung Kubernetes GitOps controller vì platform chạy ECS Fargate.

Git lưu Terraform, task-definition/AppSpec template, service registry,
CloudWatch alarms và GitHub Actions workflows.

Application release và infrastructure release có ranh giới rõ:

- Terraform sở hữu hạ tầng ổn định, ECS service ban đầu, ALB, target groups,
  IAM, alarms và CodeDeploy deployment group.
- Release workflow sở hữu image SHA, task-definition revision và application
  deployment.
- Không thay image tag trong Terraform sau mỗi release để tránh Terraform và
  CodeDeploy cùng quản lý deployment state.

Với ECS service được release ngoài Terraform, resource cấu hình:

```hcl
lifecycle {
  ignore_changes = [task_definition]
}
```

Terraform vẫn quản lý desired count, network, load balancer và deployment
policy. Deploy workflow quản lý task revision và Scheduler target, đồng thời
lưu revision trước để rollback.

### 3.1 Drift detection

Workflow theo lịch chạy hằng ngày:

```text
terraform plan -detailed-exitcode
0 → không có drift
1 → plan lỗi, gửi alert
2 → có drift hoặc configuration chưa apply, gửi Slack alert
```

Slack nhận environment, workflow URL và plan summary; drift không được
auto-apply.

## 4. Deployment strategy

### 4.1 AI Engine: CodeDeploy Blue/Green

AI Engine là HTTP service đứng sau Application Load Balancer nên dùng
CodeDeploy Blue/Green với:

- Một production listener.
- Hai target group Blue và Green.
- ECS deployment controller `CODE_DEPLOY`.
- Deployment config `CodeDeployDefault.ECSCanary10Percent5Minutes`.

Traffic flow:

1. CodeDeploy tạo Green task set từ task-definition revision mới.
2. Pre-traffic smoke test gọi `/health` và một prediction fixture.
3. Chuyển 10% traffic sang Green.
4. Theo dõi CloudWatch alarms trong năm phút.
5. Nếu tất cả gate đạt, chuyển 90% traffic còn lại sang Green.
6. Giữ Blue trong bake period trước khi terminate.

Không dùng custom traffic shift ba giai đoạn vì CodeDeploy không có predefined
ECS configuration tương ứng.

### 4.2 Ingestor: ECS rolling deployment

Ingestor là long-running ECS service đọc Kinesis và không nhận user traffic qua
ALB, nên dùng ECS rolling update:

- `minimumHealthyPercent = 100`.
- `maximumPercent = 200`.
- Bật ECS deployment circuit breaker và rollback.
- Gắn CloudWatch deployment alarms.

Health gate của Ingestor gồm task health, Kinesis iterator age và InfluxDB
write error.

### 4.3 Predictor/Orchestrator: scheduled Fargate task

Predictor/Orchestrator là scheduled task, không phải service thường trực.
EventBridge Scheduler dùng ECS `RunTask` mỗi năm phút. Task chạy một prediction
cycle rồi thoát:

1. Đọc metric window từ Timestream for InfluxDB.
2. Gọi AI Engine `/v1/predict`.
3. Ghi prediction vào InfluxDB và audit object vào S3.
4. Nếu AI trả `503` hoặc timeout ba lần liên tiếp, mở circuit breaker và chạy
   static-threshold fallback.

Release workflow đăng ký revision, chạy `RunTask` smoke test rồi cập nhật
Scheduler target. Rollback trỏ target về revision trước. Scheduler có retry
policy và DLQ.

### 4.4 Abort criteria và rollback

AI Engine rollback nếu:

- Error rate vượt 1%.
- P99 latency vượt 800 ms.
- Pre/post-traffic test thất bại.

CodeDeploy tự redeploy last-known-good revision và chuyển traffic về Blue.
Mục tiêu chuyển traffic về Blue là dưới 60 giây và phải được benchmark trong
staging; mục tiêu toàn ECS service ổn định trở lại là dưới năm phút.

Nếu Ingestor không đạt steady state hay alarm chuyển `ALARM`, ECS deployment
circuit breaker rollback về task revision hoàn thành gần nhất. Orchestrator
rollback bằng cách đưa Scheduler target về task revision trước. Infrastructure
rollback dùng PR revert và `terraform apply`; không rollback state file thủ
công.

## 5. Environment separation

Mỗi environment có ECS cluster, state key, prefix và tag riêng trong shared
AWS account.

| Environment | Branch/trigger | Mục đích | Deployment |
|---|---|---|---|
| Sandbox | Manual hoặc feature validation | Thử nghiệm nhanh và kiểm tra Terraform | Apply có manual gate |
| Staging | Merge vào `develop` | Integration AI–CDO, load test, curveball | Tự deploy sau CI pass |
| Production | Merge `develop` → `main` | Production-ready design | Design-only; manual approval nếu demo |

Sandbox có thể scale desired count về 0 ngoài giờ để tiết kiệm; naming, state
và IAM isolation vẫn giữ nguyên.

## 6. Secrets in pipeline

GitHub Actions xác thực AWS bằng OIDC:

```yaml
permissions:
  id-token: write
  contents: read
```

Workflow dùng `aws-actions/configure-aws-credentials` để lấy STS credential
ngắn hạn; không lưu static AWS key trong GitHub Secrets.

Tách IAM role theo nhiệm vụ:

- **CI role**: push đúng ECR repository, đọc metadata cần thiết.
- **Plan role**: đọc resource và truy cập state/lock object; không deploy.
- **Deploy role**: apply environment, đăng ký task definition, cập nhật ECS và
  khởi tạo CodeDeploy.

Application secret nằm trong Secrets Manager; pipeline chỉ truyền ARN.
Gitleaks chạy trên PR và log phải redact credential.

## 7. Service onboarding deployment

Onboarding là đăng ký service vào telemetry và baseline pipeline:

1. Thêm `tenant_id`, `service_id`, metric whitelist, unit và retention policy
   vào service registry có version control.
2. Pull request được review và merge.
3. Deploy cấu hình mới cho Ingestor; cấp producer quyền tối thiểu để ghi đúng
   Kinesis stream.
4. Producer gửi metric có schema bắt buộc vào Kinesis.
5. Fargate Ingestor validate, batch và ghi metric bằng Influx Line Protocol
   vào Timestream for InfluxDB.
6. Smoke test query metric và xác minh hiển thị trên Managed Grafana.
7. Nhóm AI manual-trigger baseline training khi đã có đủ dữ liệu.

Record sai schema được log và chuyển đến failure destination đã khóa trong
Telemetry Contract.

## 8. Observability stack

| Thành phần | Công cụ | Metric/evidence |
|---|---|---|
| Time-series source | Amazon Timestream for InfluxDB, Single-AZ cho POC | Metrics và predictions; bucket retention 90 ngày |
| Dashboard | Amazon Managed Grafana | Metrics, prediction, recommendation và annotation |
| ECS logs | CloudWatch Logs | Structured JSON, correlation ID, retention 14 ngày |
| Ingest monitoring | CloudWatch | Kinesis throughput/throttling, `GetRecords.IteratorAgeMilliseconds`, InfluxDB write errors |
| Serving monitoring | CloudWatch | ALB 5xx, error rate, p50/p99 latency, task health, circuit-breaker state |
| Audit | S3 SSE-KMS | Prediction audit, retention 90 ngày |
| Scheduling | EventBridge Scheduler → ECS `RunTask` | Khởi chạy Predictor/Orchestrator mỗi năm phút |
| Notification | SNS/Slack | Deploy, rollback, alarm và Terraform drift |

Smoke test sau deployment cần chứng minh:

1. Ingest một telemetry fixture vào Kinesis.
2. Metric query được trong Timestream for InfluxDB.
3. Orchestrator gọi được AI endpoint.
4. Prediction được ghi vào Timestream.
5. Audit object xuất hiện trong S3.
6. AI `503` hoặc timeout kích hoạt static-threshold fallback.

## 9. Open questions

- [ ] AI Deployment Contract đã khóa ECR ownership, container port, `/health`,
  CPU/memory và task role chưa?
- [ ] Telemetry Contract chọn failure destination nào cho record sai schema?
- [ ] Shared AWS account có cho phép tạo GitHub OIDC provider và các
  least-privilege deployment role không?
- [ ] Ai sở hữu Slack webhook/SNS topic cho deployment và drift notification?
- [ ] Repository admin đã bật branch protection và GitHub Environment approval
  cho `develop`/`main` chưa?

## Related documents

- [`02_infra_design.md`](02_infra_design.md) - Runtime architecture và component ownership.
- [`03_security_design.md`](03_security_design.md) - IAM, network, encryption và audit controls.
- [`08_adrs.md`](08_adrs.md) - Quyết định Terraform, ECS và deployment strategy.
- [AWS ECS CodeDeploy Blue/Green](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/deployment-type-bluegreen.html)
- [EventBridge Scheduler ECS target](https://docs.aws.amazon.com/scheduler/latest/APIReference/API_Target.html)
- [Timestream for InfluxDB](https://docs.aws.amazon.com/timestream/latest/developerguide/timestream-for-influxdb.html)
- [Terraform S3 backend](https://developer.hashicorp.com/terraform/language/backend/s3)
- [GitHub Actions OIDC với AWS](https://docs.github.com/en/actions/how-tos/secure-your-work/security-harden-deployments/oidc-in-aws)
