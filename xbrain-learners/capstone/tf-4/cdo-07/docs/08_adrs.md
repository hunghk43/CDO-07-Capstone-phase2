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


