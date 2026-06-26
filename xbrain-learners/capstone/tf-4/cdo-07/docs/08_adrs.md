# Hồ sơ Quyết định Kiến trúc - CDO-07 · Task Force 4

<!-- Chủ sở hữu tài liệu: CDO-07
     Trạng thái: Đang ghi liên tục W11-W12. Chỉ thêm mới - KHÔNG xóa ADR cũ.
     Cập nhật lần cuối: 2026-06-26 -->

> **Quy tắc**: Khi 1 ADR bị thay thế, đánh dấu `Trạng thái: Thay thế bởi ADR-NNN`. KHÔNG xóa.
> **Mục tiêu**: ≥3 ADR hoàn chỉnh Pack #1 (W11 T6) · ≥5 ADR Pack #2 (W12 T4)

---

## ADR-000 - Góc độ hạ tầng ban đầu: Kinesis + Timestream

- **Trạng thái**: Thay thế bởi ADR-001
- **Ngày**: 2026-06-22
- **Bối cảnh**: Bản phác thảo ban đầu CDO-07 chọn TSDB-Centric Hybrid Streaming — mock services đẩy metric vào Kinesis Data Streams → Firehose → Lambda Transformer (lọc PII) → Amazon Timestream. AI Engine (ECS Fargate) truy vấn cửa sổ 2h từ Timestream, EventBridge kích hoạt mỗi 5 phút. Timestream được chọn vì hỗ trợ time-series query độ trễ thấp, Kinesis làm bộ đệm hấp thụ spike 3×.
- **Quyết định**: Kinesis Data Streams (3 shard) + Firehose + Lambda Transformer + Amazon Timestream làm stack chính.
- **Hệ quả**:
  - Timestream bị **chặn do tài khoản** — dịch vụ không khả dụng trong tài khoản AWS capstone
  - Chi phí ước tính $179.92/tháng, chỉ cách ngưỡng circuit breaker $180 đúng $0.08
  - Kinesis Firehose + Lambda Transformer thêm độ phức tạp không cần thiết cho 6 ngày W12
- **Phương án đã xem xét**: Không có — bị loại hoàn toàn do blocker khả dụng dịch vụ

> **Thay thế bởi ADR-001** (2026-06-25): Timestream không khả dụng trong tài khoản capstone buộc team đánh giá lại toàn bộ stack. Chuyển sang ADOT + AMP — rẻ hơn 60%, quen thuộc hơn với team, zero-ops.

---

## ADR-001 - Góc độ hạ tầng chính: Event-Driven + ADOT/AMP

- **Trạng thái**: Đã chấp nhận
- **Ngày**: 2026-06-25
- **Bối cảnh**: ADR-000 bị chặn do Timestream không khả dụng. TF4 yêu cầu thu nạp time-series khối lượng lớn từ 3 mock service tier-1, AI Engine phát hiện drift với thời gian dự báo ≥15 phút, hiển thị annotation trên Grafana, ngân sách $200/tháng. Team cần góc độ khả thi trong 6 ngày W12 với zero-ops overhead.
- **Quyết định**: Chọn **Event-Driven + ADOT/AMP**: k6 → ALB → mock services (ECS Fargate) → **ADOT Sidecar** thu thập metric → **Amazon Managed Prometheus (AMP)** làm TSDB → **Amazon Managed Grafana** hiển thị + annotation. AI Engine (ECS Fargate) truy vấn AMP qua PromQL (range query cửa sổ 2h), EventBridge kích hoạt mỗi 5 phút qua Lambda Window Feeder, Fail-Open Fallback (ngưỡng tĩnh) khi AI timeout, SSM Parameter Store làm công tắc `InferenceEnabled` cho cost circuit breaker.
- **Hệ quả**:
  - AMP hỗ trợ PromQL native — team quen thuộc, không cần học cú pháp SQL mới như Timestream
  - ADOT Sidecar chuẩn OpenTelemetry, tích hợp thẳng vào ECS task definition — loại bỏ hoàn toàn pipeline Kinesis
  - Chi phí giảm 60% so với ADR-000: $145.15/tháng (80.6% ngân sách), dư $54.85
  - Amazon Managed Grafana có plugin AMP datasource tích hợp sẵn — không cần cấu hình thêm
  - Toàn bộ traffic đi qua VPC Endpoints, không cần NAT Gateway
  - ADOT Sidecar tiêu thụ thêm 0.25 vCPU / 0.5 GB mỗi ECS task (+$35.56/tháng cho 4 task)
  - VPC Endpoints chiếm 20% tổng ngân sách ($28.80) — cần thiết nhưng tốn kém
- **Phương án đã xem xét**:
  - **Kinesis + Timestream (ADR-000)**: loại — Timestream bị chặn tài khoản, chi phí sát ngưỡng $180
  - **Lakehouse (S3 + Athena)**: loại — độ trễ truy vấn Athena 2–10 giây, có nguy cơ vượt quá thời gian dự báo ≥15 phút; batch delay của Glue không phù hợp thu nạp thời gian thực
  - **CloudWatch Custom Metrics**: loại — tự động nén dữ liệu sau 15 ngày, mất tín hiệu slow drift cho AI; chi phí bùng nổ với 600+ metric × $0.30/metric/tháng

---

## ADR-002 - Thu thập và lưu trữ metric: ADOT Sidecar + AMP

- **Trạng thái**: Đã chấp nhận
- **Ngày**: 2026-06-25
- **Bối cảnh**: Sau khi chốt góc độ ADOT/AMP (ADR-001), cần quyết định cụ thể về (1) cơ chế đẩy metric từ mock services vào AMP và (2) cấu hình AMP làm TSDB chính. Phương án thay thế là giữ lại pipeline Kinesis nhưng thay đích đến từ Timestream sang AMP.
- **Quyết định**: Chọn **ADOT Sidecar** chạy trong cùng ECS task definition với mỗi service. ADOT scrape Prometheus-format metrics theo chuẩn OpenTelemetry, đẩy vào **AMP workspace** qua remote_write (HTTPS, xác thực SigV4). AI Engine truy vấn AMP qua PromQL `query_range` với `start=now-2h`. Retention 150 ngày (vượt yêu cầu 90 ngày). Chi phí $0.93/tháng ở quy mô demo (10M samples).
- **Hệ quả**:
  - Loại bỏ Kinesis Data Streams + Firehose + Lambda Transformer: tiết kiệm ~$32.85/tháng và giảm đáng kể độ phức tạp
  - ADOT là bản phân phối OpenTelemetry do AWS quản lý — chuẩn ngành, zero-ops sidecar, xác thực SigV4 tích hợp sẵn
  - Multi-tenant qua label `service_id` — cô lập truy vấn bằng PromQL filter, không cần bảng riêng
  - ADOT Sidecar lỗi sẽ ảnh hưởng toàn bộ việc thu thập metric của task đó — cần liveness probe riêng
  - Không còn khả năng replay 24h như Kinesis Firehose — debug phải dùng Grafana historical query
  - AMP không hỗ trợ SQL joins — AI Engine phải tự tương quan nhiều metric trong code
- **Phương án đã xem xét**:
  - **Kinesis Data Streams + Lambda Transformer**: loại — chi phí $32.85/tháng Kinesis Provisioned; pipeline phức tạp không cần thiết khi AMP chấp nhận remote_write trực tiếp
  - **Đẩy metric trực tiếp từ code ứng dụng (SDK)**: loại — tăng coupling giữa business logic và observability; vi phạm tách biệt mối quan tâm (separation of concerns)
  - **Prometheus tự quản trên EC2**: loại — overhead vận hành vi phạm yêu cầu zero-ops; ~$35/tháng + thời gian vá lỗi; không phù hợp 6 ngày W12

---

## ADR-003 - Nền tảng tính toán cho AI Serving: ECS Fargate

- **Trạng thái**: Đã chấp nhận
- **Ngày**: 2026-06-23
- **Bối cảnh**: AI Serving cần expose `POST /v1/predict`, duy trì trạng thái Circuit Breaker liên tục giữa các request (3 lần lỗi → OPEN → Fail-Open với ngưỡng tĩnh), duy trì connection pooling ổn định tới AMP (truy vấn cửa sổ 2h) và S3 (ghi audit log). EventBridge kích hoạt định kỳ mỗi 5 phút. Lambda cold start (~500ms+) xung đột với yêu cầu giữ trạng thái và p99 latency <500ms.
- **Quyết định**: Chọn **ECS Fargate** làm nền tảng tính toán cho AI Serving. Container image lưu trên **Amazon ECR**, ECS task chạy trong Private Subnet App Tier, expose qua ALB target group tại path `/v1/predict`. Task definition cấu hình ADOT Sidecar để tự động phát metric AI (latency dự đoán, drift_detected rate, confidence score) vào AMP — nhất quán với mock services.
- **Hệ quả**:
  - Duy trì trạng thái Circuit Breaker liên tục trong vòng đời task — không bị đặt lại mỗi lần invoke như Lambda
  - Connection pooling tới AMP ổn định, tránh overhead khởi tạo lại kết nối mỗi request
  - Không cold start — đáp ứng thời gian dự báo ≥15 phút và chu kỳ kích hoạt 5 phút của EventBridge
  - Chi phí cố định cao hơn Lambda khi lưu lượng thấp — Fargate task chạy liên tục, không scale-to-zero
- **Phương án đã xem xét**:
  - **Lambda**: loại — cold start xung đột với yêu cầu duy trì trạng thái Circuit Breaker; mỗi lần invoke phải khởi tạo lại kết nối AMP; timeout 15 phút có thể chặn cửa sổ test 2h+
  - **EKS**: loại — overhead quản lý control plane K8s (RBAC, networking, node group) không cần thiết ở quy mô capstone 3 service; ECS Fargate đáp ứng đủ mà không cần quản lý control plane

---

## ADR-004 - Lưu trữ Audit Log: Amazon S3 + Lifecycle Policy

- **Trạng thái**: Đã chấp nhận
- **Ngày**: 2026-06-25
- **Bối cảnh**: Hệ thống cần lưu Audit Log từ mỗi lần AI Serving gọi ML Model, phục vụ kiểm toán, điều tra sự cố, truy vết lịch sử dự đoán và compliance lưu trữ 1 năm. Dữ liệu được truy cập thường xuyên chủ yếu trong 90 ngày đầu, sau đó rất thấp. Không yêu cầu truy vấn thời gian thực.
- **Quyết định**: Chọn **Amazon S3** với **S3 Lifecycle Policy** tự động chuyển tier:

  | Giai đoạn     | Storage Class           |
  |---------------|-------------------------|
  | 0 – 30 ngày   | S3 Standard             |
  | 30 – 90 ngày  | S3 Infrequent Access    |
  | 90 – 365 ngày | S3 Glacier Deep Archive |
  | Sau 365 ngày  | Xóa tự động             |

  AI Serving ghi Audit Log trực tiếp vào S3 (PutObject, SSE-KMS) sau mỗi lần dự đoán. Khi cần audit: khôi phục từ Glacier (12–48h), sau đó truy vấn bằng Amazon Athena.

- **Hệ quả**:
  - Glacier Deep Archive rẻ hơn S3 Standard ~95% — tối ưu chi phí dài hạn khi log tích lũy theo năm
  - Lifecycle Policy tự động chuyển tier, không cần can thiệp thủ công
  - Khả năng mở rộng gần như không giới hạn — không cần provision throughput như DynamoDB
  - SSE-KMS nhất quán với baseline bảo mật toàn hệ thống
  - Dữ liệu trong Glacier cần 12–48h để khôi phục — không truy xuất tức thì khi audit khẩn cấp với data >90 ngày
- **Phương án đã xem xét**:
  - **Amazon DynamoDB**: loại — chi phí lưu trữ dài hạn cao hơn S3 khi data tích lũy; millisecond latency của DynamoDB không mang lại giá trị cho use case Ghi Một Lần, Đọc Hiếm Khi (WORR); không có lifecycle policy tự động giảm tier cost tương đương Glacier

---

## ADR-005 - Hiển thị quan sát: Amazon Managed Grafana

- **Trạng thái**: Đã chấp nhận
- **Ngày**: 2026-06-25
- **Bối cảnh**: Hệ thống cần dashboard hiển thị metric từ AMP và overlay annotation kết quả drift detection từ AI Engine. Yêu cầu: tích hợp native với AMP datasource, không quản lý server/phiên bản, phù hợp timeline 6 ngày W12.
- **Quyết định**: Chọn **Amazon Managed Grafana** (1 workspace, 1 active editor/admin user, $9.00/tháng). AMP datasource plugin tích hợp sẵn — không cần cấu hình thủ công. AI Engine POST annotation qua Grafana HTTP API sau mỗi sự kiện phát hiện drift, hiển thị overlay trực tiếp trên biểu đồ time-series.
- **Hệ quả**:
  - AWS quản lý provisioning, vá lỗi, tính sẵn sàng cao — zero-ops cho máy chủ Grafana
  - Plugin AMP datasource tích hợp sẵn với xác thực SigV4 — không cần cài đặt hay cấu hình thêm
  - Tích hợp AWS SSO/IAM native — không cần quản lý user/password Grafana riêng
  - License $9.00/workspace/tháng — chi phí cố định thêm so với self-hosted (miễn phí)
  - Tùy chỉnh bị giới hạn — không thể cài plugin tùy ý như self-hosted
- **Phương án đã xem xét**:
  - **Grafana tự lưu trú trên ECS Fargate**: loại — cần quản lý image, task definition, nâng cấp phiên bản, backup; overhead vận hành không phù hợp timeline 6 ngày; phải cấu hình thủ công AMP datasource + xác thực SigV4
  - **CloudWatch native dashboards**: loại — không hỗ trợ PromQL/AMP datasource; overlay annotation kém linh hoạt hơn Grafana; không phù hợp góc độ khác biệt ADOT/AMP

---

<!-- Chỉ thêm ADR mới ở dưới. Khi 1 ADR bị thay thế, đánh dấu Trạng thái + link chuyển tiếp. -->
