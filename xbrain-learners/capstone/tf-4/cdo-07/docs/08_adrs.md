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

## ADR-001 - Infra angle: Event-driven hybrid (ECS Fargate + Kinesis + Timestream + Amazon Managed Grafana)
- **Status**: Accepted
- **Date**: 2026-06-23 (Updated 2026-06-25)
- **Context**: TF4 yêu cầu ingest high-volume time-series từ 3 tier-1 service, AI engine
  predict drift với lead time ≥15 phút, Grafana annotation overlay, budget $200/2 tuần.
  Serverless-first (ADR-000) bị loại vì AMP pull-based không match push-ingest và Lambda
  không giữ được Circuit Breaker state. CDO-07 cần angle khác biệt so với 2 CDO còn lại.
- **Decision**: Chọn **event-driven** hybrid: k6 → ALB → mock services emit metric →
  Kinesis Data Streams (3 shards) → Kinesis Firehose → Lambda Transformer (PII drop) →
  Timestream. AI Serving trên ECS Fargate, EventBridge trigger mỗi 5 phút qua Lambda
  Window Feeder (query 2h window, gọi /v1/predict, timeout 5.0s), có Fail-Open Fallback
  (static thresholds) khi AI timeout, và SSM Param Store làm toggle inference_enabled
  cho cost circuit breaker (Lambda CB, xem mục 7 + component table trong 02_infra_design.md).
  Output qua Amazon Managed Grafana annotation + SNS → Slack. Audit log ghi S3 SSE-KMS.
- **Consequence**:
  - Kinesis Data Streams buffer + absorb traffic spike (sudden spike 3× scenario) mà
  không drop metric, đồng thời partition theo service_id cho multi-tenant isolation
  và có 24h replay capability cho testing (xem 02_infra_design.md mục 4.4)
  - ECS Fargate giữ Circuit Breaker state liên tục, không cold start
  - Amazon Managed Grafana: tích hợp trực tiếp Timestream plugin, không cần tự quản lý server/version/availability của Grafana — đổi lại tốn license $9/workspace/month so với self-host, nhưng giảm ops overhead phù hợp timeline 3 tuần
  - Lambda Window Feeder + Fail-Open Fallback + SSM toggle thêm 1 lớp resilience: khi AI Engine timeout hoặc bị tắt qua cost circuit breaker, hệ thống fail-open sang static thresholds (CPU>85%, Mem>90%, Conn>450, Queue>10k) thay vì mất giám sát hoàn toàn
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

## ADR-004 - Ingestion pipeline: Kinesis Data Streams + Firehose giữa Mock Services và Timestream

- **Status**: Accepted (Updated 2026-06-25 — xem ghi chú Update trong ADR-001)
- **Date**: 2026-06-23
- **Context**: 3 mock service (Payment GW, Ledger, Fraud detection) liên tục bắn metric ra ngoài.
  Nếu cứ để chúng ghi thẳng vào Timestream, một traffic spike (test scenario yêu cầu chịu
  được spike 3×) sẽ làm nghẽn hoặc rớt metric vì Timestream cần ghi theo batch mới tối
  ưu, không hợp để ghi từng record lẻ tẻ ngay khi nó tới. Ngoài ra, theo mục 4.4 của
  02_infra_design.md, mỗi service cần được cách ly throughput với nhau (multi-tenant), và
  team cũng muốn có khả năng replay lại data trong 24h để debug khi cần, vì timeline W12
  chỉ có 6 ngày để build nên không có nhiều cơ hội tái tạo lại sự cố thủ công.
- **Decision**: Cho mock service bắn metric vào **Kinesis Data Streams** (3 shard, dùng
  `service_id` làm partition key), từ đó chảy qua **Kinesis Firehose** (buffer 60 giây)
  tới **Lambda Transformer**. Lambda này làm 2 việc trong 1 bước: định dạng lại data cho
  đúng schema Timestream, và lọc field nhạy cảm (PII) trước khi ghi. Sau đó mới ghi vào
  Timestream. Luồng này hoàn toàn tách biệt với luồng AI Serving (đọc baseline từ S3, query
  Timestream cửa sổ 2h) — hai bên không đụng vào nhau.
- **Consequence**: Kinesis đứng giữa làm bộ đệm nên spike 3× không làm mock service bị
  nghẽn hay rớt request. Vì partition theo `service_id`, mỗi service tự động được route vào
  shard riêng, throughput không lấn nhau (đúng yêu cầu chống noisy-neighbor ở mục 4.4) — và
  còn có thêm 24h replay để debug, thứ mà SQS không có. Việc gộp transform + PII filter vào
  cùng 1 Lambda cũng giúp đỡ một bước trung gian, không cần tách riêng component lọc PII.

  Đổi lại, data sẽ không xuất hiện trong Timestream ngay tức thì — phải đi qua Kinesis rồi
  buffer ở Firehose 60s rồi mới tới Lambda transform — nên cần để ý độ trễ này không ăn hết
  ngân sách thời gian so với yêu cầu lead time ≥15 phút của AI Serving. Một rủi ro khác là
  Timestream không hỗ trợ upsert, nên nếu Lambda Transformer phải retry (do lỗi tạm thời),
  có thể ghi trùng cùng timestamp — đã ghi nhận ở ADR-002, cần có idempotency check để xử lý.
  Kinesis On-Demand tự scale shard theo traffic nên không phải lo capacity planning thủ công,
  nhưng vẫn có quota giới hạn của AWS cần theo dõi nếu traffic vượt xa mức thiết kế ban đầu
  (xem thêm mục 3.3 weakness trong 02_infra_design.md).
- **Alternatives considered**:
  - **Ghi thẳng từ mock service vào Timestream, không qua queue/stream nào**: bị loại vì
    không chịu được spike 3× — sẽ rớt metric hoặc làm response chậm lại
  - **Amazon SQS**: bị loại vì SQS không hỗ trợ partition theo `service_id`, nên không cách
    ly được throughput giữa các service, và cũng không có khả năng replay. Kinesis On-Demand
    vận hành đơn giản tương đương SQS mà lại có thêm 2 cái này, nên chọn Kinesis hợp lý hơn
  - **Apache Kafka trên MSK**: bị loại vì phải tự quản lý cluster, chi phí cao hơn mức ngân
    sách $200/1 tháng cho phép, không hợp với timeline ngắn của dự án này

---

## ADR-005 - Audit Log storage: Amazon S3 + Lifecycle Policy over DynamoDB

- **Status**: Accepted
- **Date**: 2026-06-25
- **Context**: Hệ thống cần lưu trữ Audit Log sinh ra từ mỗi lần AI Serving gọi ML Model,
  phục vụ 4 mục đích: Audit (kiểm toán), Incident Investigation (điều tra sự cố),
  Prediction Traceability (truy vết lịch sử dự đoán), và đáp ứng yêu cầu compliance lưu trữ dữ liệu.

  Yêu cầu chính:
  - Lưu trữ tối đa **1 năm**.
  - Dữ liệu được truy cập thường xuyên chủ yếu trong **90 ngày đầu**; sau đó truy cập rất thấp.
  - Tối ưu chi phí lưu trữ dài hạn khi khối lượng log tăng liên tục theo số lần prediction.
  - Không yêu cầu truy xuất thời gian thực hay độ trễ mili giây — audit chỉ diễn ra theo lịch
    hoặc khi có yêu cầu điều tra cụ thể.
  - Cần khả năng mở rộng không giới hạn khi số lượng user, frequency gọi model, hoặc số
    lượng ML model tăng trong tương lai.

  Hai phương án được đánh giá: **(1) Amazon S3** và **(2) Amazon DynamoDB**.

- **Decision**: Chọn **Amazon S3** làm hệ thống lưu trữ chính cho Audit Log, quản lý dữ liệu
  bằng **S3 Lifecycle Policy** tự động chuyển tier theo thời gian:

  | Giai đoạn       | Storage Class               |
  |-----------------|-----------------------------|
  | 0 – 90 ngày     | S3 Standard                 |
  | 90 – 365 ngày   | S3 Glacier Deep Archive     |
  | Sau 365 ngày    | Xóa tự động (Expiration rule) |

  AI Serving ghi Audit Log trực tiếp vào S3 (PutObject) sau mỗi lần predict. Dữ liệu được
  mã hóa SSE-KMS (nhất quán với ADR-001). Khi có yêu cầu audit hoặc điều tra, dữ liệu trong
  Glacier Deep Archive được khôi phục trước theo lịch với thời gian chờ chấp nhận được
  (12–48h Standard Retrieval).

- **Consequence**:
  - **Ưu điểm**:
    - Giảm chi phí lưu trữ dài hạn đáng kể: Glacier Deep Archive rẻ hơn S3 Standard ~95%
      và rẻ hơn DynamoDB storage nhiều lần khi data volume tăng theo tháng/năm
    - Lifecycle Policy tự động chuyển tier — không cần can thiệp thủ công, không cần
      capacity planning phức tạp
    - Scalability gần như không giới hạn: S3 không cần provision throughput hay shard như DynamoDB
    - Tích hợp tự nhiên với Athena / Glue nếu cần phân tích log theo batch trong tương lai
    - SSE-KMS native, nhất quán với cấu hình security toàn hệ thống (ADR-001)
  - **Nhược điểm**:
    - Dữ liệu trong Glacier Deep Archive cần 12–48h để khôi phục trước khi truy cập —
      cần lên kế hoạch trước các đợt audit với dữ liệu > 90 ngày
    - Không hỗ trợ truy vấn trực tiếp trên object (cần Athena hoặc tải xuống để query)
    - Không phù hợp cho bất kỳ use case nào cần đọc Audit Log theo thời gian thực

- **Alternatives considered**:
  - **Amazon DynamoDB**: rejected — chi phí lưu trữ dài hạn cao hơn S3 khi data tích lũy
    theo năm; tối ưu cho OLTP workload với truy vấn độ trễ thấp, nhưng Audit Log không có
    yêu cầu đó; không có cơ chế lifecycle policy tự động giảm tier cost tương đương Glacier;
    lợi thế millisecond latency của DynamoDB không mang lại giá trị tương xứng cho use case
    Write Once, Read Rarely (WORR) của Audit Log
