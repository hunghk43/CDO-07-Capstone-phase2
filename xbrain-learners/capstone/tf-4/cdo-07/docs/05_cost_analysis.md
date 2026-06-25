# Cost Analysis - Task force 4 · CDO 07

## 1. Cost model per tenant (forecast)

Dựa trên thiết kế kiến trúc hiện tại, hệ thống phục vụ chính xác 3 tenants (`payment-gateway`, `ledger-service`, `fraud-detection`).

| Component | Unit cost (Total) | Tenant avg usage | $/tenant/month (N=3) |
| --- | --- | --- | --- |
| **Compute** (ECS Fargate - AI Engine) | $11.25/tháng | Request-level routing theo `service_id`, shared compute pool | $3.75 |
| **Database** (Amazon Timestream) | $28.50/tháng | Pooled Table, Query Scan theo `service_id` filter | $9.50 |
| **Storage** (S3 - baseline + audit) | $1.65 + $0.50 = $2.15/tháng | Phân vùng thư mục theo `{service_id}` / `{date}` | $0.72 |
| **Data transfer** | $0/tháng | Toàn bộ traffic đi qua VPC Endpoints thay vì NAT Gateway | $0.00 |
| **AI inference** | N/A | ML baseline chạy trên Fargate, không dùng LLM API | $0.00 |
| **Observability** (Managed Grafana + CloudWatch) | $9.00 + $8.11 = $17.11/tháng | Dashboard clone với variable filter theo tenant | $5.70 |
| **Shared Core Infra** (ALB, Kinesis, Firehose, VPC Endpoints, Load Gen, Lambda, Budgets) | $120.91/tháng | Hạ tầng nền tảng bắt buộc để vận hành luồng stream | $40.30 |
| **Total / tenant / month** | **$179.92** |  | **$59.97** |

### 1.1 Architecture Insights: Phân tích Cost Model

Mức chi phí **$59.97/tenant/tháng** là khá cao so với kỳ vọng ban đầu. Dưới góc nhìn System Design, điều này xuất phát từ chiến lược **Serverless-first + Managed TSDB** mà nhóm đã chọn. Phần lớn ngân sách ($120.91) rơi vào **Fixed Cost** của hạ tầng mạng và streaming:

* **VPC Endpoints ($41.50)**: Trả phí duy trì theo giờ (hourly charge) không phụ thuộc vào việc có 1 hay 100 tenant.
* **Kinesis Provisioned ($32.85)**: Trả phí theo Shard Hour. Dù 3 tenant không dùng hết throughput 1MB/s/shard, ta vẫn phải trả mức phí nền này.
* **ALB ($18.43)**: Phí duy trì Load Balancer base cost.

Đây là một trade-off kiến trúc kinh điển: Đổi chi phí cố định (Fixed Cost) lấy sự giảm thiểu tối đa rủi ro vận hành (Zero Ops overhead) và khả năng mở rộng tự động trong thời gian ngắn (4h deploy).

< TODO W12: Thu thập actual usage (Data Ingested/Query Scan) từ 3 tenant trong quá trình test để tính toán marginal cost (biến phí phát sinh thêm khi có tenant thứ 4). >

## 2. Cost at scale (Economies of Scale)

Bảng dưới đây minh họa rõ lý do tại sao kiến trúc này tối ưu ở quy mô lớn thay vì quy mô nhỏ. Khi N tăng, Fixed Cost được khấu hao (amortized), giúp giảm mạnh chi phí trung bình.

| Tenant count | Monthly total cost | Avg per-tenant | Ghi chú kiến trúc |
| --- | --- | --- | --- |
| **3 (Current)** | **$179.92** | **$59.97** | Bị áp đảo bởi base cost của VPC Endpoints & Kinesis |
| 10 | ~$185.00 | $18.50 | Timestream storage/query tăng nhẹ, Core Infra giữ nguyên |
| 50 | ~$210.00 | $4.20 | Đạt điểm hiệu quả chi phí. Kinesis có thể cần thêm shard |
| 200 | ~$350.00 | $1.75 | Tiệm cận target NFR ban đầu |

< TODO W12: Nếu biến phí Kinesis PUT / Timestream Query Scan tăng đáng kể khi N tăng qua các bài stress test, cần cập nhật lại forecast cho N=50 và N=200 >

## 3. Cost optimization applied

☐ Spot instances cho non-critical workload (Có thể áp dụng cho Load Generation task để giảm $22.83)
☐ Reserved capacity cho baseline AI Engine
☑ **S3 lifecycle tiering:** Standard → IA sau 30 ngày cho Audit Logs ($0.50/tháng).
☐ DynamoDB on-demand vs provisioned (Không áp dụng, dùng Timestream)
☐ Bedrock prompt caching (Không áp dụng theo constraint: Không sử dụng LLM)
☐ Right-sizing per ECS task/Lambda memory
☑ **Log retention tiering:** CloudWatch retention giới hạn 7 ngày ($8.11).
☑ **Data transfer optimization:** Kết nối private qua VPC Endpoints thay vì NAT Gateway ($41.50). Mặc dù base cost cao nhưng chặn đứng hoàn toàn phí Data Processing của NAT.

## 4. Measured actual (Pack #2 only - fill in W12)

### 4.1 2-week capstone spend

| Service | Forecast | Actual | Delta |
| --- | --- | --- | --- |
| Compute | $34.08 | $X | ±X% |
| Database (Timestream) | $28.50 | $X | ±X% |
| Storage / Streaming | $43.70 | $X | ±X% |
| Networking / API | $59.93 | $X | ±X% |
| Observability | $17.11 | $X | ±X% |
| **Total** | **$179.92** | **$X** | **±X%** |

### 4.2 Per-tenant actual

| Tenant test | Service mix | $/day | Extrapolate $/month |
| --- | --- | --- | --- |
| **Tenant-1** | `payment-gateway` | $X | $X |
| **Tenant-2** | `kyc-service` | $X | $X |
| **Tenant-3** | `reporting-api` | $X | $X |

### 4.3 Cost-per-correct-decision (joint with AI eval)

| Metric | Value |
| --- | --- |
| Total AI calls in capstone | N |
| Correct decisions | M |
| Total AI inference cost (ECS Fargate fraction) | $11.25 |
| **Cost per correct decision** | **$11.25 / M** |

## 5. Cost guardrails (Risk Warning)

* **Nguy cơ cấu trúc (Architectural Risk):** Hệ thống đang set AWS Budgets alert ở mức **$180**. Với dự phóng chi phí là **$179.92**, mức đệm (buffer) hiện tại chỉ là **$0.08**.
* **Hành động:** Lambda circuit breaker qua SSM sẽ bị trigger ngay lập tức chỉ với một đợt traffic spike nhỏ. Cần điều chỉnh Alert threshold lên $195 hoặc tối ưu Fargate Load Gen xuống mức thấp hơn.
* **Per-tenant quota enforced via API rate limit:** Đang triển khai tại Kinesis shard limits (partition key = `service_id`).

## 6. Cost recommendations for production

* **Fargate Compute Savings Plan:** Cam kết 1-3 năm sẽ giúp giảm 20-50% chi phí cho AI Engine và Load Gen.
* **Kinesis On-Demand:** Cân nhắc chuyển Kinesis Data Streams sang mode On-Demand nếu traffic thực tế của 3 tenants có tính chất bursty (thất thường) và idle nhiều.
* **Self-managed VPC Endpoints (Gateway vs Interface):** Chuyển S3 Endpoint sang dạng Gateway (Miễn phí) thay vì Interface để tiết kiệm hourly cost.

## Related documents

* `02_infra_design.md` - Phân tích kiến trúc gốc tạo ra mức phí $179.92.
* `08_ai_api_contract.md §Rate limiting` - Quota guardrail feeds row "Per-tenant quota".
* `07_test_report.md` - Load test results validate Timestream Query Scan assumptions.
