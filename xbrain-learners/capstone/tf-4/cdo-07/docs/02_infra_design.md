# Infrastructure Design - Task Force 4 · CDO-07

<!-- Doc owner: Nhóm CDO7
     Status: Draft (W11 T3-T4) → Final (W11 T6 Pack #1) → Updated (W12 T4 Pack #2)
     Word target: 1500-2500 từ -->

## 1. Architecture diagram

![CDO7 Architecture](images/CDO7.drawio.png)

*Caption: Hệ thống Foresight Lens predictive monitoring với telemetry pipeline từ mock services qua Kinesis Streams đến Timestream DB, AI inference engine chạy trên ECS Fargate, và dashboard tích hợp Grafana annotations. Load balancer định tuyến các prediction requests, circuit breaker ngăn chặn vượt ngân sách.*

## 2. Component table

| Component | AWS Service | Reason | Cost note |
|---|---|---|---|
| **Compute** | ECS Fargate | AI inference engine cần uptime 24/7, loại bỏ Lambda cold start với ML libraries | $11.25 |
| **API entry** | Application Load Balancer | Định tuyến `/v1/predict` requests, health checks, quản lý target group | $18.43 |
| **Database** | Amazon Timestream | Tối ưu time-series, auto-tiered storage (7 ngày Memory + 90 ngày Magnetic), truy vấn SQL | $28.50 |
| **Storage** | S3 Standard | ML model baselines theo service, configuration files, lifecycle policies | $1.65 |
| **Event bus** | Kinesis Data Streams (Provisioned) | 3 shards phân vùng theo service_id, khả năng replay 24h, cách ly multi-tenant | $32.85 |
| **Observability** | Amazon Managed Grafana | Tích hợp trực tiếp Timestream, annotations overlay, quản lý workspace | $9.00 |
| **Load Generation** | ECS Fargate (3 tasks) | Mock payment/kyc/reporting services, mô phỏng Node.js async I/O | $22.83 |
| **Stream Delivery** | Kinesis Data Firehose | Chuyển đổi format sang Timestream, cấu hình delivery buffer | $4.35 |
| **Audit Storage** | S3 Standard + KMS | Prediction audit logs định dạng JSON, mã hóa at-rest, lifecycle sang IA sau 30 ngày | $0.50 |
| **Functions** | Lambda + EventBridge | window-feeder (trigger 5 phút), pii-filter (per-event), cost circuit breaker | $0.85 |
| **Networking** | VPC Endpoints | ECR, CloudWatch, Timestream, S3, Kinesis - kết nối private | $41.50 |
| **Logging** | CloudWatch Logs | Centralized logging tất cả services, retention 7 ngày | $8.11 |
| **Cost Control** | AWS Budgets | Ngưỡng cảnh báo $180, trigger Lambda circuit breaker | $0.10 |
| **Total** | | | **$179.92** |

## 3. Differentiation angle deep-dive

### 3.1 Why this angle?

**Serverless-first + Managed TSDB**: Chọn kiến trúc này để tối ưu cho ràng buộc capstone - zero ops overhead, chi phí dự đoán được, và timeline triển khai nhanh. Các pattern thay thế (self-managed clusters, traditional monitoring stack) yêu cầu đầu tư vận hành đáng kể không phù hợp với khung thời gian triển khai 3 tuần.

Các quyết định kiến trúc chính:
- Managed services thay vì self-hosted (Timestream vs Prometheus cluster)  
- ECS Fargate always-on thay vì Lambda (loại bỏ vấn đề ML cold start)
- Xử lý stream-native (Kinesis) thay vì batch ETL patterns
- Single TSDB table thay vì per-service databases (đơn giản vận hành)

### 3.2 Where we excel (numbers)

| Axis | My number | Competing angle estimate |
|---|---|---|
| Chi phí/tháng | $179.92 (89.96% budget utilization) | $200+ (EC2 + EBS + ops tools) |
| Thời gian triển khai | <4h (Terraform + container deploy) | 2-3 ngày (cluster setup + config) |
| Ops overhead (giờ/tuần) | 0 (fully managed services) | 8-12 (patching, monitoring, scaling) |
| Thời gian scale | Auto (managed service scaling) | Manual (cluster resize + rebalancing) |

### 3.3 Weakness acknowledged

- **Vendor lock-in**: Phụ thuộc nặng vào AWS managed services (Timestream, Kinesis, Fargate). Trade-off chấp nhận được cho timeline capstone vs tính portable production.
- **Single region**: Không có redundancy cross-region để tối thiểu hóa chi phí data transfer. Recovery strategy được ghi nhận trong ADR nhưng chưa triển khai.
- **Managed service limits**: Bị giới hạn bởi AWS service quotas (Kinesis shard limits, Timestream ingestion rates) vs khả năng scale self-managed.

## 4. Multi-tenant approach

### 4.1 Tenant model

- **Tenant ID format**: `service_id` (payment-gateway, kyc-service, reporting-api)
- **Header**: `service_id`, `tenant_id`, `metric_type` mandatory trong Kinesis payload
- **Subscription tiers**: All 3 services Tier-1 (per-service baseline models, 5-min prediction intervals)

### 4.2 Isolation pattern

- **Data isolation**: Pool model - single Timestream table `service-metrics` với phân tách dimension-level qua WHERE filters
- **Compute isolation**: Shared ECS Fargate AI Engine với request-level routing theo payload service_id
- **Tại sao pattern này**: Cân bằng hiệu quả chi phí vs độ mạnh isolation. Single table → cấu hình Grafana đơn giản, shared compute → tiết kiệm $60-80/tháng vs per-tenant containers

### 4.3 Tenant onboarding flow

```
1. Đăng ký service_id → k6 allowlist + cấu hình mock engine
2. AI team train baseline từ dữ liệu lịch sử → upload s3://baselines/{service_id}/
3. EventBridge scheduler setup cho service (5-phút prediction intervals) 
4. Clone Grafana dashboard template → cấu hình service_id variable filter
5. Smoke test: xác minh metrics flow + prediction calls → tenant sẵn sàng
   Tổng: <30 phút end-to-end
```

### 4.4 Noisy neighbor mitigation

- **Per-tenant quota**: Kinesis partition key = `service_id` → định tuyến shard tự động, cách ly throughput
- **Kinesis shard limits**: Mỗi shard 1MB/sec hoặc 1000 records/sec capacity per partition
- **Resource reservation**: AI Engine có thể thêm per-service rate limits (future enhancement)
- **Audit isolation**: S3 audit logs được phân vùng theo date path `s3://audit-logs/{year}/{month}/{day}/` với prediction_id filename

## 5. Alternatives considered

### 5.1 Compute layer

- **Option A**: Lambda + API Gateway - Ưu điểm: chi phí theo invoke, auto-scaling · Nhược điểm: cold start 5-10s với ML libraries, giới hạn 15 phút
- **Option B**: EKS + Kubernetes - Ưu điểm: container orchestration, linh hoạt · Nhược điểm: overhead quản lý cluster, chi phí cao hơn
- ✅ **Đã chọn**: ECS Fargate + ALB - Lý do: Loại bỏ vấn đề cold start performance, latency dự đoán được <200ms, không cần quản lý cluster

### 5.2 Database

- **Option A**: Self-managed Prometheus trên EC2 - Ưu điểm: PromQL quen thuộc, open source · Nhược điểm: ops overhead, ~$90/tháng chi phí EC2
- **Option B**: InfluxDB Cloud - Ưu điểm: tối ưu time-series · Nhược điểm: vendor lock-in, chi phí data transfer
- ✅ **Đã chọn**: Amazon Timestream - Lý do: Zero-ops managed service, auto-tiered storage (7d + 90d), truy vấn SQL, $28.50/tháng

### 5.3 Event streaming

- **Option A**: SQS Standard - Ưu điểm: setup đơn giản, chi phí thấp · Nhược điểm: không partitioning, không replay capability
- **Option B**: Apache Kafka trên MSK - Ưu điểm: high throughput, mature ecosystem · Nhược điểm: quản lý cluster, chi phí cao hơn
- ✅ **Đã chọn**: Kinesis Data Streams (Provisioned) - Lý do: Service_id partitioning quan trọng cho multi-tenant isolation, replay 24h cho testing, chi phí dự đoán được

## 6. Scaling strategy

- **Vertical**: ECS auto-scaling CPU >70% trong 2 phút → khởi chạy task bổ sung
- **Horizontal**: Kinosis Provisioned mode thêm/bớt shards theo traffic spikes (manual scaling)
- **Triggers**: CloudWatch alarms - ECS CPU utilization, Kinesis incoming records, Lambda error rates

## 7. Failure modes + recovery

| Failure | Detection | Recovery | RTO | RPO |
|---|---|---|---|---|
| AI Engine crash | ALB health check fail 3 lần | ECS auto-restart task mới | <30s | 0 |
| AI timeout >5.0s | Request timeout exception | Fail-open sang static thresholds | <1s | 0 |
| Timestream outage | Firehose delivery errors | Kinesis 24h buffer retention | Auto | 0 |
| Budget vượt $180 | AWS Budgets alert | Lambda circuit breaker qua SSM | <5s | 0 |
| VPC endpoint failure | Connection timeout | Multi-endpoint redundancy | <30s | 0 |

## Related documents

- [`01_requirements_analysis.md`](01_requirements_analysis.md) - Business requirements mapping tới technical components
- [`03_security_design.md`](03_security_design.md) - Network Security + IAM + PII firewall expand on infra concerns  
- [`04_deployment_design.md`](04_deployment_design.md) - IaC Terraform + CI/CD GitOps cho infra này
- [`05_cost_analysis.md`](05_cost_analysis.md) - Per-service cost model $179.92/tháng breakdown chi tiết + optimization strategies
- [`08_adrs.md`](08_adrs.md) - Infra architecture decisions (ADR-001 to ADR-004)