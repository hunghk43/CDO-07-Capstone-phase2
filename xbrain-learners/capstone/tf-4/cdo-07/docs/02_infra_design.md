# Infrastructure Design - Task Force 4 · CDO-07

<!-- Doc owner: Nhóm CDO7
     Status: Draft (W11 T3-T4) → Final (W11 T6 Pack #1) → Updated (W12 T4 Pack #2)
     Word target: 1500-2500 từ -->

## 1. Architecture diagram

![CDO7 Architecture](images/CDO7.drawio.png)

*Caption: Hệ thống TF4 Foresight Lens - CDO Platform Architecture với k6 Load Generator, mock services trên ECS Fargate, AI Engine với ML models, Amazon Managed Prometheus cho time-series storage, EventBridge scheduling, SNS notifications, và Grafana dashboard. Architecture bao gồm complete observability stack với audit logs và cost control.*

## 2. Component table

| Component | AWS Service | Reason | Cost note |
|---|---|---|---|
| **Compute** | ECS Fargate | AI inference engine + 3 mock services, 900 vCPU-hour + 1,800 GB-hour | $44.43 |
| **ADOT Sidecar Overhead** | ECS Fargate (additional) | ADOT collectors per task, 0.25 vCPU/0.5GB × 4 tasks × 720h | $35.56 |
| **API entry** | Application Load Balancer | Định tuyến requests, health checks, 1 ALB + 1 LCU average | $21.96 |
| **Database** | Amazon Managed Prometheus (AMP) | Time-series storage, 10M samples ingested + queried, PromQL queries | $0.93 |
| **Storage** | S3 Standard + Glacier | ML baselines, audit logs, lifecycle policies, 10GB + 5GB archive | $0.79 |
| **Event Orchestration** | EventBridge + Lambda | Scheduling every 5min, window feeder functions, circuit breaker | $0.03 |
| **Observability** | Amazon Managed Grafana | Dashboard visualization, 1 active editor/admin user | $9.00 |
| **Data Collection** | ADOT (AWS Distro for OpenTelemetry) | Sidecar collectors, metrics ingestion pipeline | Included above |
| **Container Registry** | Amazon ECR | Container image storage cho ECS services, 5GB storage | $0.50 |
| **Audit & Compliance** | S3 + CloudWatch Logs | Prediction audit logs, centralized logging, 5GB logs | $3.15 |
| **Functions** | Lambda + SNS | Cost circuit breaker, alert notifications, Slack integration | $0.02 |
| **Networking** | VPC Endpoints (4 endpoints) | ECR, CloudWatch, AMP, private service access, 720h × 4 | $28.80 |
| **Cost Control** | AWS Budgets + Parameter Store | Budget thresholds, inference control flags | $0.00 |
| **Total** | | | **$145.15** |

## 3. Differentiation angle deep-dive

### 3.1 Why this angle?

**Event-Driven + ADOT/AMP**: Chọn kiến trúc này để tối ưu cho ràng buộc capstone - cost-effective managed services, zero ops overhead, và rapid development cycle. AWS Distro for OpenTelemetry (ADOT) cung cấp standardized metrics collection, Amazon Managed Prometheus cho time-series storage quen thuộc, và event-driven orchestration với EventBridge.

Các quyết định kiến trúc chính:
- ADOT + AMP thay vì Kinesis + Timestream (60% cheaper, familiar Prometheus ecosystem)
- EventBridge scheduling thay vì stream processing (simpler event-driven patterns)  
- Sidecar ADOT collectors cho standardized observability
- Managed Grafana với native AMP integration

### 3.2 Where we excel (numbers)

| Axis | My number | Competing angle estimate |
|---|---|---|
| Chi phí/tháng | $145.15 (80.6% budget utilization) | $200+ (EC2 + EBS + ops tools) |
| Thời gian triển khai | <3h (Terraform + ADOT + containers) | 2-3 ngày (cluster setup + config) |
| Ops overhead (giờ/tuần) | 0 (fully managed services) | 8-12 (patching, monitoring, scaling) |
| Thời gian scale | Auto (managed service scaling) | Manual (cluster resize + rebalancing) |

### 3.3 Weakness acknowledged

- **ADOT overhead**: Sidecar collectors require additional 0.25 vCPU/0.5GB per task (+$35.56), critical cho standardized telemetry collection.
- **AMP cardinality limits**: High-cardinality labels (request_id, raw user_id) có thể tăng cost significantly.
- **VPC endpoint dependency**: 20% total cost từ VPC endpoints, cần thiết cho private networking nhưng expensive.

## 4. Multi-tenant approach

### 4.1 Tenant model

- **Tenant ID format**: `service_id` (payment-gateway, kyc-service, reporting-api)
- **Header**: `service_id`, `tenant_id`, `metric_type` mandatory trong Kinesis payload
- **Subscription tiers**: All 3 services Tier-1 (per-service baseline models, 5-min prediction intervals)

### 4.2 Isolation pattern

- **Data isolation**: Label-based model - Prometheus metrics với service_id labels, query filtering qua PromQL
- **Compute isolation**: Shared ECS Fargate AI Engine với request-level routing theo service identifier  
- **Tại sao pattern này**: Prometheus native multi-tenancy qua labels, cost-effective shared compute, familiar PromQL syntax cho team

### 4.3 Tenant onboarding flow

```
1. Đăng ký service_id → k6 test suite configuration + mock service deployment
2. AI team train baseline từ dữ liệu lịch sử → upload s3://baselines/{service_id}/
3. EventBridge rules setup cho service scheduling và notifications
4. Grafana dashboard provisioning → service_id label filters và alerts
5. Smoke test: xác minh metrics ingestion + prediction API + notifications
   Tổng: <25 phút end-to-end
```

### 4.4 Noisy neighbor mitigation

- **Per-tenant quota**: Prometheus label cardinality limits, EventBridge rule throttling per service
- **Resource reservation**: ECS task CPU/memory limits, ALB target group health checks
- **Rate limiting**: API Gateway usage plans cho prediction endpoints, circuit breaker patterns
- **Monitoring isolation**: Separate CloudWatch log groups, SNS topic subscriptions per service tier

## 5. Alternatives considered

### 5.1 Compute layer

- **Option A**: Lambda + API Gateway - Ưu điểm: cost per invoke, auto-scaling · Nhược điểm: cold start 5-10s với ML libraries, 15min execution limit không đáp ứng **test window ≥2h requirement**
- **Option B**: EKS + Kubernetes - Ưu điểm: container orchestration, unlimited runtime · Nhược điểm: ops overhead, không phù hợp với **$200/tháng budget constraint**
- ✅ **Đã chọn**: ECS Fargate - Lý do: **Long-running processes cho 2h+ test windows**, predictable latency <200ms cho **lead time ≥15min**, managed service phù hợp budget

### 5.2 Database

- **Option A**: Self-managed Prometheus trên EC2 - Ưu điểm: full control, PromQL familiar · Nhược điểm: ops overhead vi phạm **zero-ops requirement**, ~$35/tháng + maintenance time
- **Option B**: Amazon Timestream - Ưu điểm: managed service, auto-scaling · Nhược điểm: **account availability blocker**, SQL learning curve cho team, projected cost $45-85/tháng
- ✅ **Đã chọn**: Amazon Managed Prometheus - Lý do: **Native support cho ≥90 day retention**, PromQL queries tối ưu cho **multi-tenant ≥3 services**, cost-effective $0.93/tháng cho demo scale

### 5.3 Time-series data collection

- **Option A**: Kinesis Data Streams - Ưu điểm: high throughput, ordered processing · Nhược điểm: stream processing complexity, không cần thiết cho **synthetic workload + k6 load test** use case
- **Option B**: Direct CloudWatch Metrics - Ưu điểm: native AWS integration · Nhược điểm: không đáp ứng **high-volume time-series requirement (50k events/sec peak)**
- ✅ **Đã chọn**: ADOT + EventBridge - Lý do: **Standardized telemetry collection** theo OpenTelemetry spec, **event-driven scheduling** phù hợp với **manual baseline refresh weekly cadence**, cost-effective cho capstone scale

### 5.4 Prediction scheduling

- **Option A**: Cron jobs trên EC2 - Ưu điểm: flexible scheduling · Nhược điểm: infrastructure management overhead, không scale với **per-service baseline requirement**
- **Option B**: Kinesis Analytics realtime - Ưu điểm: streaming analytics · Nhược điểm: overkill cho **manual approval gate**, complexity không cần thiết
- ✅ **Đã chọn**: EventBridge + Lambda - Lý do: **Event-driven patterns** phù hợp **predict + recommend only** (không auto-remediation), **cost circuit breaker integration** cho $200 budget cap, flexible scheduling cho multiple test scenarios

## 6. Scaling strategy

- **Vertical**: ECS auto-scaling CPU >70% trong 2 phút → khởi chạy task bổ sung
- **Horizontal**: EventBridge rules scaling, SNS fanout patterns cho multiple consumers  
- **Triggers**: CloudWatch alarms - ECS CPU utilization, Prometheus ingestion rate, EventBridge rule invocations

## 7. Failure modes + recovery

| Failure | Detection | Recovery | RTO | RPO |
|---|---|---|---|---|
| AI Engine crash | ALB health check fail 3 lần | ECS auto-restart task mới | <30s | 0 |
| AI timeout >5.0s | Request timeout exception | Fail-open sang static thresholds | <1s | 0 |
| Prometheus ingestion lag | CloudWatch metrics delay | EventBridge retry với exponential backoff | <2min | <30s |
| Budget vượt $180 | AWS Budgets alert | Lambda circuit breaker qua SNS + parameter store | <5s | 0 |
| VPC endpoint failure | Connection timeout | Multi-endpoint redundancy + fallback routes | <30s | 0 |

## Related documents

- [`01_requirements_analysis.md`](01_requirements_analysis.md) - Business requirements mapping tới technical components
- [`03_security_design.md`](03_security_design.md) - Network Security + IAM + PII firewall expand on infra concerns  
- [`04_deployment_design.md`](04_deployment_design.md) - IaC Terraform + CI/CD GitOps cho infra này
- [`05_cost_analysis.md`](05_cost_analysis.md) - Per-service cost model $145.15/tháng breakdown chi tiết + ADOT sidecar overhead $35.56 + optimization strategies
- [`08_adrs.md`](08_adrs.md) - Infra architecture decisions (ADR-001 to ADR-004)