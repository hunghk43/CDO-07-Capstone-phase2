# Cost Analysis - Task force 4 · CDO 07

## 1. Cost model per tenant (forecast)

Dựa trên thiết kế kiến trúc hiện tại (Event-Driven + ADOT/AMP trên ECS Fargate), hệ thống phục vụ chính xác 3 tenants (`payment-gateway`, `ledger-service`, `fraud-detection`).

| Component | Unit cost (Total) | Tenant avg usage | $/tenant/month (N=3) |
| --- | --- | --- | --- |
| **Compute** (ECS Fargate - AI Engine + 3 mock services) | $44.43/tháng | Request-level routing theo `service_id`, shared compute pool, 900 vCPU-hour + 1,800 GB-hour | $14.81 |
| **ADOT Sidecar Overhead** (ECS Fargate, additional) | $35.56/tháng | Sidecar collector per task, 0.25 vCPU/0.5GB × 4 tasks × 720h | $11.85 |
| **Database** (Amazon Managed Prometheus - AMP) | $0.93/tháng | Label-based isolation theo `service_id`, PromQL query filtering, 10M samples ingested + queried | $0.31 |
| **Storage** (S3 Standard + Glacier - baseline + audit) | $0.79/tháng | Phân vùng theo `{service_id}` cho ML baselines, 10GB + 5GB archive | $0.26 |
| **Data transfer** | $0/tháng | Toàn bộ traffic nội bộ đi qua VPC Endpoints thay vì NAT Gateway | $0.00 |
| **AI inference** | N/A | ML baseline chạy trên Fargate, không dùng LLM API | $0.00 |
| **Observability** (Managed Grafana + ADOT pipeline) | $9.00/tháng | Dashboard với `service_id` label filter, 1 active editor/admin user | $3.00 |
| **Shared Core Infra** (ALB, EventBridge+Lambda, VPC Endpoints x4, ECR, Audit S3+CloudWatch Logs, SNS, Budgets) | $54.44/tháng | Hạ tầng nền tảng bắt buộc để vận hành luồng event-driven | $18.15 |
| **Total / tenant / month** | **$145.15** |  | **$48.38** |

### 1.1 Architecture Insights: Phân tích Cost Model

Mức chi phí **$48.38/tenant/tháng** đã giảm đáng kể (~19% tổng cost, ~$11.6/tenant) so với phương án trước đó (Kinesis + Timestream). Dưới góc nhìn System Design, điều này xuất phát từ việc chuyển sang chiến lược **ADOT + Amazon Managed Prometheus (AMP)** thay cho Kinesis Data Streams + Timestream. Phần ngân sách lớn nhất giờ rơi vào **Compute** (AI Engine + ADOT sidecar), không còn nằm ở streaming pipeline:

* **ECS Fargate Compute ($44.43)**: Bao gồm AI inference engine + 3 mock services. Đây là chi phí biến đổi theo workload, không phải fixed cost thuần như Kinesis trước đây.
* **ADOT Sidecar Overhead ($35.56)**: Chi phí mới phát sinh do chuyển sang standardized telemetry collection (OpenTelemetry) - đánh đổi cho khả năng quan sát đồng nhất, không phụ thuộc nhà cung cấp.
* **VPC Endpoints ($28.80)**: Vẫn là fixed cost theo giờ (4 endpoints × 720h), không phụ thuộc số tenant - chiếm ~20% tổng chi phí hệ thống.
* **ALB ($21.96)**: Phí duy trì Load Balancer base cost, không đổi dù có 1 hay nhiều tenant.
* **AMP ($0.93)**: Giảm mạnh so với Timestream ($28.50) nhờ pricing model theo samples ingested/queried, phù hợp quy mô demo.

Đây là một trade-off kiến trúc khác so với bản trước: đổi một phần Fixed Cost (Kinesis shard-hour, Timestream storage) sang Variable Cost gắn với compute (ADOT sidecar theo số task), đồng thời vẫn giữ nguyên tắc **Zero Ops overhead** và khả năng scale tự động.

< TODO W12: Thu thập actual usage (AMP samples ingested/queried, ECS task count thực tế) từ 3 tenant trong quá trình test để tính toán marginal cost (biến phí phát sinh thêm khi có tenant thứ 4). >

## 2. Cost at scale (Economies of Scale)

Bảng dưới đây minh họa lý do tại sao kiến trúc ADOT/AMP tối ưu hơn ở cả quy mô nhỏ và lớn, vì phần lớn fixed cost (VPC Endpoints, ALB) được khấu hao khi N tăng, còn AMP/Compute scale gần tuyến tính theo nhu cầu thực.

| Tenant count | Monthly total cost | Avg per-tenant | Ghi chú kiến trúc |
| --- | --- | --- | --- |
| **3 (Current)** | **$145.15** | **$48.38** | Bị áp đảo bởi Compute (ECS Fargate) + ADOT sidecar overhead, không còn bởi streaming layer |
| 10 | ~$160.00 | $16.00 | AMP ingestion tăng nhẹ, ADOT sidecar tăng theo số task bổ sung, Core Infra giữ nguyên |
| 50 | ~$230.00 | $4.60 | Đạt điểm hiệu quả chi phí; ECS auto-scaling thêm task khi CPU >70% |
| 200 | ~$420.00 | $2.10 | Tiệm cận target NFR ban đầu; cần đánh giá lại AMP cardinality limits |

< TODO W12: Nếu biến phí AMP samples ingested / ECS task scaling tăng đáng kể khi N tăng qua các bài stress test, cần cập nhật lại forecast cho N=50 và N=200 >

## 3. Cost optimization applied

☑ **S3 lifecycle tiering:** Standard → Glacier cho ML baselines + Audit Logs ($0.79/tháng).
☑ **Right-sizing ADOT sidecar:** Giới hạn 0.25 vCPU/0.5GB per task để tối thiểu overhead ($35.56/tháng cho 4 tasks).
☑ **Log retention tiering:** CloudWatch Logs giới hạn dung lượng cho Audit & Compliance ($3.15/tháng).
☑ **Data transfer optimization:** Kết nối private qua VPC Endpoints (ECR, CloudWatch, AMP) thay vì NAT Gateway, chặn đứng hoàn toàn phí Data Processing của NAT dù base cost theo giờ cao ($28.80).

## 4. Measured actual (Pack #2 only - fill in W12)

### 4.1 2-week capstone spend

| Service | Forecast | Actual | Delta |
| --- | --- | --- | --- |
| Compute (ECS Fargate + ADOT sidecar) | $79.99 | $X | ±X% |
| Database (AMP) | $0.93 | $X | ±X% |
| Storage (S3) | $0.79 | $X | ±X% |
| Networking (ALB + VPC Endpoints) | $50.76 | $X | ±X% |
| Observability (Managed Grafana) | $9.00 | $X | ±X% |
| Audit, Registry & Functions (S3+CloudWatch, ECR, Lambda+SNS) | $3.67 | $X | ±X% |
| **Total** | **$145.15** | **$X** | **±X%** |

### 4.2 Per-tenant actual

| Tenant test | Service mix | $/day | Extrapolate $/month |
| --- | --- | --- | --- |
| **Tenant-1** | `payment-gateway` | $X | $X |
| **Tenant-2** | `ledger-service` | $X | $X |
| **Tenant-3** | `fraud-detection` | $X | $X |

### 4.3 Cost-per-correct-decision (joint with AI eval)

| Metric | Value |
| --- | --- |
| Total AI calls in capstone | N |
| Correct decisions | M |
| Total AI inference cost (ECS Fargate AI Engine fraction) | $44.43 |
| **Cost per correct decision** | **$44.43 / M** |

## 5. Cost guardrails (Risk Warning)

* **Nguy cơ cấu trúc (Architectural Risk):** Hệ thống đang set AWS Budgets alert ở mức **$180**. Với dự phóng chi phí là **$145.15** (80.6% budget utilization), mức đệm (buffer) hiện tại là **$34.85**, an toàn hơn đáng kể so với phương án trước.
* **Hành động:** Lambda circuit breaker qua Parameter Store sẽ trigger khi chi phí thực tế vượt $180. Với buffer hiện tại (~24%), rủi ro bị trigger bởi traffic spike nhỏ thấp hơn nhiều so với phương án Kinesis/Timestream cũ (buffer chỉ $0.08).
* **Per-tenant quota enforced via:** Prometheus label cardinality limits + EventBridge rule throttling per `service_id`; API Gateway usage plans cho prediction endpoints (xem `02_infra_design.md §4.4`).

## 6. Cost recommendations for production

* **Fargate Compute Savings Plan:** Cam kết 1-3 năm sẽ giúp giảm 20-50% chi phí cho AI Engine, mock services và ADOT sidecar.
* **AMP cardinality control:** Giới hạn high-cardinality labels (request_id, raw user_id) để tránh chi phí AMP tăng đột biến khi scale lên N=50/200.
* **VPC Endpoints (Gateway vs Interface):** Chuyển S3 Endpoint sang dạng Gateway (miễn phí) thay vì Interface để tiết kiệm hourly cost trong tổng $28.80/tháng hiện tại.
* **ADOT sidecar tuning:** Đánh giá lại tần suất export metrics để giảm thêm overhead $35.56/tháng nếu lead time ≥15min vẫn được đảm bảo với interval dài hơn.

## Related documents

* `02_infra_design.md` - Phân tích kiến trúc gốc (Event-Driven + ADOT/AMP) tạo ra mức phí $145.15.
* `08_ai_api_contract.md §Rate limiting` - Quota guardrail feeds row "Per-tenant quota".
* `07_test_report.md` - Load test results validate AMP ingestion/query assumptions.
