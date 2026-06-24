# Architecture Decision Records - CDO-07 · Task Force 4

<!-- Doc owner: CDO-07
     Status: Ongoing log W11-W12. Append-only - KHÔNG xóa ADR cũ.
     Last updated: 2026-06-23
     Word count target: 800-1500 từ (cả file) -->

> **Append-only**: khi 1 ADR bị thay thế, đánh dấu `Status: Superseded by ADR-NNN`. KHÔNG xóa.
> **Target**: ≥3 ADR hoàn chỉnh Pack #1 (W11 T6) · ≥5 ADR Pack #2 (W12 T4)

---

## ADR-000 - Infra angle ban đầu: Serverless-first (Lambda + AMP)

- **Status**: Superseded by ADR-001
- **Date**: 2026-06-22
- **Context**: Draft ban đầu CDO-07 chọn serverless-first (Lambda cho AI engine + Amazon
  Managed Prometheus cho storage) vì ops overhead thấp và cost pay-per-invocation.
- **Decision**: Lambda + AMP làm primary stack.
- **Consequence**:
  - Không cần manage server, cost thấp khi idle
  - AMP là pull-based, không match push-ingest pattern từ microservice
  - Lambda cold start ~500ms, Circuit Breaker cần stateful process → không phù hợp
- **Alternatives considered**: N/A (draft ban đầu, chưa compare đủ)

> **Superseded by ADR-001** (2026-06-23): sau khi review diagram và TF4 requirements
> chi tiết, team đổi sang event-driven hybrid. Lý do cụ thể xem ADR-001.

---

## ADR-001 - Infra angle: Event-driven hybrid (ECS Fargate + SQS + Timestream + Grafana OSS)

- **Status**: Accepted
- **Date**: 2026-06-23
- **Context**: TF4 yêu cầu ingest high-volume time-series từ 3 tier-1 service, AI engine
  predict drift với lead time ≥15 phút, Grafana annotation overlay, budget $200/2 tuần.
  Serverless-first (ADR-000) bị loại vì AMP pull-based không match push-ingest và Lambda
  không giữ được Circuit Breaker state. CDO-07 cần angle khác biệt so với 2 CDO còn lại.
- **Decision**: Chọn **event-driven hybrid**: k6 → WAF → ALB → Ingest Service → SQS →
  Ingest Worker → Timestream. AI Serving trên ECS Fargate, EventBridge trigger mỗi 5 phút,
  output qua Grafana OSS annotation + SNS → Slack. Audit log ghi S3 SSE-KMS.
- **Consequence**:
  - SQS buffer absorb traffic spike (sudden spike 3× scenario) mà không drop metric
  - ECS Fargate giữ Circuit Breaker state liên tục, không cold start
  - Grafana OSS self-hosted: không tốn AMG license $9/user/month, full control annotation API
  - Nhiều component hơn serverless-first: tăng surface area debug trong 6 ngày W12
  - Timestream SQL syntax khác PromQL: cần sync với AI team trong Telemetry Contract
- **Alternatives considered**:
  - **Serverless-first (AMP + Lambda)**: rejected - AMP pull-based không match push pattern,
    Lambda cold start conflict Circuit Breaker (xem ADR-000)
  - **Lakehouse (S3 + Athena)**: rejected - Athena latency 2-10s → risk miss lead time ≥15 phút
  - **Kinesis thay SQS**: rejected - shard management phức tạp hơn, capstone không cần replay

---

## ADR-002 - Time-series storage: Amazon Timestream

- **Status**: Accepted
- **Date**: 2026-06-23
- **Context**: Telemetry Contract yêu cầu storage support time-series query hiệu quả, không
  phải raw S3. AI engine query 2h window gần nhất để detect drift. Retention ≥90 ngày.
  Volume capstone: 3 service × ~20 metrics, nhưng design phải scale tới 50k events/sec.
- **Decision**: **Amazon Timestream** với 2-tier: memory store 2 ngày (fast query AI predict)
  + magnetic store 90 ngày (cheap, đáp ứng retention). Ingest Worker BatchWrite 100 records/call.
  AI engine query qua VPC Endpoint, không ra Internet.
- **Consequence**:
  - Managed service: AWS handle provisioning/scaling, CDO-07 không manage server
  - 2-tier tự động: hot data memory store cho AI query, cold data magnetic store cho audit
  - IAM auth + VPC Endpoint native, không cần custom auth layer
  - Vendor lock-in: migrate sau capstone cần rewrite query layer trong AI engine
  - Không support upsert: Ingest Worker retry cùng timestamp → duplicate, cần idempotency check
- **Alternatives considered**:
  - **AMP**: PromQL native, Grafana plug-and-play. Rejected - pull-based không match Ingest Worker
    push pattern (đã loại ở ADR-001)
  - **S3 + Athena**: cheapest $0.023/GB. Rejected - query latency 2-10s block AI predict call
  - **InfluxDB self-hosted**: powerful TSDB. Rejected - ops overhead quản lý server không
    phù hợp 6 ngày build W12.

---

## ADR-003 - Compute cho AI Serving: ECS Fargate over Lambda / EKS

- **Status**: Accepted
- **Date**: 2026-06-23
- **Context**: AI Serving expose `POST /v1/predict`, nhận traffic qua ALB path-based routing (`/v1/predict`), thực hiện drift detection + capacity recommendation, và phải maintain Circuit Breaker (3× fail → OPEN → static CloudWatch alarms → Fail-Open) liên tục giữa các request. AI Serving cũng được EventBridge trigger định kỳ mỗi 5 phút để chạy batch prediction, đồng thời cần giữ connection pooling ổn định tới Amazon Timestream (query 2h window) và Audit Table để ghi `output { drift_detected, confidence, recommendation, evidence_link }`. ADR-000 đã loại Lambda do cold start (~500ms) xung đột với yêu cầu giữ state Circuit Breaker; ADR-001 chốt hướng event-driven hybrid nhưng chưa quyết định cụ thể giữa các lựa chọn container compute.
- **Decision**: Chọn **ECS Fargate** làm compute layer cho AI Serving (cùng pattern với Ingest Service, Ingest Worker). Container image build và push lên **Amazon ECR**, ECS task pull image, chạy trong Private Subnet App Tier, expose qua ALB target group ở path `/v1/predict`.
- **Consequence**:
  - Giữ được Circuit Breaker state liên tục trong vòng đời task — không bị reset mỗi lần invoke như Lambda
  - Connection pooling tới Timestream + Audit Table ổn định, tránh overhead tạo lại connection mỗi request
  - Không cold start: đáp ứng tốt yêu cầu lead time ≥15 phút cho drift prediction và nhịp trigger 5 phút từ EventBridge
  - Phải tự quản lý task definition, service auto-scaling (CPU/queue depth), và ECR lifecycle — overhead vận hành cao hơn Lambda
  - Cost cố định cao hơn Lambda khi traffic thấp do Fargate task chạy liên tục, không scale-to-zero
- **Alternatives considered**:
  - **Lambda**: rejected — cold start xung đột với yêu cầu giữ Circuit Breaker state liên tục (đã loại từ ADR-000); thêm vào đó EventBridge trigger 5 phút + connection pooling tới Timestream sẽ kém hiệu quả nếu mỗi invocation phải khởi tạo lại connection
  - **EKS**: rejected — overhead vận hành K8s control plane (RBAC, networking, node group) không cần thiết ở scale capstone (3 service, 1 AZ); ECS Fargate đã đáp ứng đủ yêu cầu mà không cần quản lý control plane

---

## ADR-004 - Queue/decoupling: SQS giữa Ingest Service và Ingest Worker

- **Status**: Accepted
- **Date**: 2026-06-23
- **Context**: Ingest Service nhận telemetry từ 3 tier-1 service qua ALB path `/v1/telemetry` (push pattern, HTTPS POST qua WAF). Test scenario yêu cầu chịu được sudden spike 3× traffic mà không drop metric. Nếu Ingest Service write trực tiếp và đồng bộ vào Timestream, một traffic spike sẽ block request hoặc gây timeout, vì Timestream BatchWrite cần batch 100 records/call để tối ưu throughput và cost — không phù hợp ghi single-record theo từng request đến.
- **Decision**: Tách **Ingest Service** (nhận request, enqueue vào SQS) và **Ingest Worker** (poll + batch từ SQS, BatchWrite 100 records/call vào Timestream) thành 2 service riêng trên ECS Fargate, decouple qua **Amazon SQS**. Ingest Worker và AI Serving đều poll SQS qua VPC Endpoint (không ra Internet).
- **Consequence**:
  - SQS đóng vai trò buffer, absorb traffic spike (sudden spike 3× scenario) mà không làm Ingest Service bị nghẽn hoặc drop request
  - Ingest Worker có thể batch 100 records/call trước khi write Timestream — tối ưu cost và throughput so với write từng record
  - Tách compute write nặng (Ingest Worker) khỏi compute nhận request (Ingest Service) — scale độc lập theo queue depth hoặc theo request rate
  - Thêm độ trễ giữa lúc nhận request và lúc data thực sự có trong Timestream (do enqueue → poll → batch), cần đảm bảo độ trễ này vẫn nằm trong khoảng cho phép so với lead time ≥15 phút của AI Serving
  - SQS không đảm bảo exactly-once theo mặc định — Ingest Worker retry khi poll lại có thể gây duplicate ghi cùng timestamp vào Timestream (Timestream không support upsert, đã ghi nhận ở ADR-002) → cần idempotency check ở Ingest Worker
  - Thêm 1 component vào kiến trúc (so với write trực tiếp), tăng surface area cần debug nếu message bị stuck hoặc vào Dead Letter Queue
- **Alternatives considered**:
  - **Write trực tiếp từ Ingest Service vào Timestream (không qua queue)**: rejected — không chịu được sudden spike 3× mà không drop metric hoặc tăng latency response cho client gửi telemetry
  - **Kinesis Data Streams**: rejected — shard management phức tạp hơn SQS, và capstone không cần khả năng replay stream (đã loại ở ADR-001 khi so sánh cho ingest pipeline tổng thể)
