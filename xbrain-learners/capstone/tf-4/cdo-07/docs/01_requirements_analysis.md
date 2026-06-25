# Requirements Analysis - Task Force 4 · CDO-07

## 1. Đề tài context

Hệ thống giám sát và dự báo chủ động **Foresight Lens** được thiết kế để giải quyết bài toán vận hành thực tế cho một khách hàng Fintech quy mô tầm trung. Hiện tại, doanh nghiệp đang phục vụ khoảng 3.5 triệu người dùng hoạt động (active users), với mức tải ngày thường đạt 2.8k Requests Per Second (RPS) và đạt đỉnh (peak traffic) lên tới 9k RPS trong các sự kiện lớn như Black Friday. Toàn bộ hệ thống core-banking và tài chính phụ trợ đang vận hành thông qua cụm hạ tầng gồm hơn 120 microservices production triển khai trên nền tảng AWS ECS Fargate, kết hợp với các CSDL RDS Aurora MySQL, DynamoDB và hệ thống hàng đợi SQS.

### Vấn đề cốt lõi của khách hàng
Trong vòng 3 tháng vừa qua, đội ngũ SRE (Site Reliability Engineering) của doanh nghiệp đã làm giảm uy tín thương hiệu khi vi phạm chỉ số SLO cam kết về độ sẵn sàng của hệ thống (Monthly Availability Target 99.9%) trong 7 lần liên tiếp. Đáng chú ý, nguyên nhân không xuất phát từ các sự cố sập nguồn thảm họa (catastrophic incidents), mà lại đến từ các lỗi cạn kiệt tài nguyên âm thầm (capacity exhaustion silent) diễn ra từ từ theo thời gian:
* CPU của các cụm cơ sở dữ liệu RDS Aurora MySQL tăng dần đều và neo giữ ở mức 100% suốt 90 phút trước khi làm nghẽn hoàn toàn kết nối (connection pool exhaustion).
* Lượng tin nhắn tồn đọng (backlog) trong hệ thống hàng đợi SQS tích tụ âm thầm lên gấp 6 lần khiến các ứng dụng tiêu thụ dữ liệu (consumers) rơi vào trạng thái timeout.
* Giới hạn kết nối (connection limit) trên Application Load Balancer (ALB) chạm ngưỡng trần mỗi khi có traffic spike vào cuối tuần.

Tất cả các sự cố trên đều bị phát hiện muộn sau khi có từ 18 đến 25 khiếu nại (support tickets) từ phía người dùng cuối phản hồi về bộ phận CS, thay vì được phát hiện chủ động từ hệ thống giám sát nội bộ. Khách hàng đã có sẵn các dashboard CloudWatch và DataDog, nhưng họ thiếu một giải pháp tự động hóa có khả năng học baseline động thay vì dựa vào các ngưỡng cấu hình tĩnh (static thresholds) dễ gây nhiễu alert (alert fatigue) hoặc bỏ sót các biến động chậm (slow drift).

### Mục tiêu của Foresight Lens
Xây dựng một hệ thống phân tích và dự báo chuỗi thời gian (time-series metrics) hoạt động liên tục 24/7 để:
1. Tự động thu thập và phân tích các chỉ số tài nguyên từ 3 dịch vụ Tier-1 cốt lõi.
2. Học tập hành vi bình thường (per-service baseline) theo chu kỳ tuần để nhận diện tính chất mùa vụ của ngành tài chính.
3. Chủ động phát tín hiệu cảnh báo (proactive ping) trước ít nhất 15 phút khi hệ thống có dấu hiệu drift hoặc sắp cạn kiệt tài nguyên (capacity exhaustion).
4. Đưa ra các khuyến nghị hành động cụ thể (Actionable Capacity Recommendation) có cấu trúc tường minh để kỹ sư SRE phê duyệt bằng tay (manual approval gate).

---

## 2. Infra non-functional requirements

Để hệ thống Foresight Lens hoạt động ổn định và đáp ứng các tiêu chuẩn khắt khe của một hệ thống tài chính, hạ tầng do nhóm CDO triển khai phải cam kết đạt được các chỉ số phi chức năng sau đây:

| Chỉ số NFR | Ngưỡng Mục tiêu (Target) | Khung Lý do & Ràng buộc Kỹ thuật (Justification) |
| :--- | :--- | :--- |
| **Multi-tenant scale** | ≥ 50 tenants | Hệ thống được thiết kế để đóng gói thành sản phẩm thương mại hóa (SaaS), cho phép quản lý và cô lập dữ liệu metric từ tối thiểu 50 tenant khách hàng khác nhau. |
| **SLO p99 latency** | < 1000ms | Áp dụng nghiêm ngặt cho điểm cuối API `/v1/predict`. Thời gian xử lý từ lúc nhận payload time-series window đến khi trả về kết quả dự báo không được quá 1 giây để bảo toàn thời gian xử lý sự cố. |
| **Availability** | ≥ 99.5% | Cam kết độ sẵn sàng ổn định cho toàn bộ pipeline ingestion và hệ thống lưu trữ dữ liệu giám sát cốt lõi, đảm bảo không làm đứt gãy luồng metric truyền về. |
| **Error rate** | < 0.5% | Tỷ lệ lỗi sinh ra trên đường truyền dẫn dữ liệu (drop metric, network error) phải được kiểm soát dưới 0.5% để tránh làm sai lệch tập dữ liệu đầu vào của mô hình AI. |
| **Cost per tenant/month** | ~$1.90 / tenant | Dựa trên mục tiêu phân bổ ngân sách tối ưu của dự án, tổng chi phí hạ tầng AWS duy trì ở mức ~$95/tháng. Với quy mô tối thiểu 50 tenants, chi phí trên mỗi tenant cực kỳ cạnh tranh. |
| **Onboarding SLA** | < 30 phút | Thời gian từ lúc một microservice mới được đăng ký vào hệ thống Foresight Lens cho đến khi hạ tầng lưu trữ và phân tách dữ liệu sẵn sàng tiếp nhận metric. |
| **Security baseline** | IAM least-privilege + audit 90 ngày | Toàn bộ các dịch vụ AWS cấu hình chặt chẽ qua IAM Roles, mã hóa dữ liệu tại chỗ (Encryption at rest) và lưu vết toàn bộ hoạt động truy cập thông qua CloudTrail để đáp ứng chuẩn SOC2. |

---

## 3. Differentiation Angle (KEY)

Sau khi nghiên cứu sâu sắc về bản chất bài toán và các rủi ro kỹ thuật liên quan đến độ trễ dữ liệu và chi phí, nhóm quyết định lựa chọn hướng kiến trúc làm điểm nhấn cạnh tranh độc quyền:

* **Angle lựa chọn:** **TSDB-Centric Hybrid Streaming (Kinesis Data Stream + Amazon Timestream)**.
* **Why this angle (Trục chiến thắng - Win Axis):** Khách hàng yêu cầu một hệ thống có khả năng đưa ra dự báo với **Lead time ≥ 15 phút** trước khi xảy ra vi phạm SLO. Để làm được điều này, dữ liệu đầu vào của AI Engine phải là dữ liệu "tươi nhất" (Real-time granularity) và giữ nguyên độ phân giải mịn trong suốt **90 ngày lưu trữ lịch sử**. 
  
  Nếu chọn hướng thiết kế Lakehouse (Option B), hệ thống sẽ bị dính độ trễ lớn do cơ chế gom lô (batching) của Kinesis Firehose và tiến trình lên lịch (schedule) của AWS Glue Job, dẫn đến nguy cơ cao bị trễ cửa sổ vàng 15 phút để cứu hệ thống. Nếu chọn hướng Managed-lite (Option C) sử dụng CloudWatch Custom Metrics, hệ thống sẽ rơi vào rủi ro tự động nén dữ liệu (down-sampling) sau 15 ngày, làm mất đi các chi tiết dịch chuyển chậm (slow drift) mà AI cần học. 
  
  Do đó, việc đưa **Amazon Timestream** làm hạt nhân lưu trữ kết hợp tầng đệm **Kinesis Data Stream** là lựa chọn tối ưu nhất. Kiến trúc này giúp ghi nhận dữ liệu thông suốt ở quy mô peak 50k events/sec, thực hiện truy vấn chuỗi thời gian (time-series query) tốc độ cao với độ trễ mili-giây, cung cấp dữ liệu thô toàn vẹn cho mô hình AI đưa ra kết quả dự báo chính xác nhất (đáp ứng tiêu chí bắt bắt được ≥ 80% drift của khách hàng).

* **Phân tích Chi phí & Biến động giữa các Option Architectural:**
  Để làm rõ tính khả thi của Option A dưới áp lực tải lớn trong ngân sách giới hạn **$200/tháng (Circuit Breaker Cap)**, nhóm thực hiện lập bảng đối chiếu cấu trúc chi phí (Cost Profile) chi tiết từ tầng nạp dữ liệu (Ingestion) đến tầng lưu trữ/truy vấn:

| Tiêu chí | Option A: TSDB-Centric (Lựa chọn của nhóm) | Option B: Lakehouse (S3 + Glue + Athena) | Option C: Managed Observability (CloudWatch Metrics) |
| :--- | :--- | :--- | :--- |
| **Cơ chế tính phí chính** | • Phí duy trì Shard + PUT Payload Units của **Kinesis Data Streams**.<br>• Phí nạp (Ingestion), lưu trữ và dung lượng quét khi truy vấn (Query Scan) của **Timestream**. | • Phí nạp qua Kinesis Firehose.<br>• Phí lưu trữ S3.<br>• Phí quét dữ liệu của Amazon Athena ($5/TB). | Phí nạp Custom Metrics theo số lượng Metric Volume ($0.30/metric/tháng cho 10k metrics đầu). |
| **Chi phí cố định (Fixed Cost)** | **Trung bình (~$30 - $45)**: Chi phí cơ sở để duy trì số lượng Kinesis Shard tối thiểu ở chế độ Provisioned ngày thường (chưa tính biến phí theo lượng data chạy demo). | **Trung bình - Cao**: Chi phí chạy Glue Job định kỳ để nén/partition dữ liệu (tối thiểu ~0.44$/DPU-Hour). | **Rất cao (Vượt Budget)**: Với 120 services × trung bình 5 metrics/service = 600 metrics × 50k events/sec sẽ làm bùng nổ (explode) chi phí Custom Metrics vượt xa mức $200. |
| **Rủi ro chi phí biến đổi (Variable Risk)** | **Cao**: <br>1. Tầng Ingestion: Lượng PUT Payload tăng mạnh khi load test/peak traffic.<br>2. Tầng Query: Nếu AI Engine gọi câu lệnh `SELECT *` quét toàn bảng liên tục, chi phí Query Scan của Timestream sẽ tăng phi mã. | **Thấp - Trung bình**: Nếu dữ liệu trên S3 được partition tốt bằng Glue, chi phí quét của Athena rất rẻ. Phí Firehose nạp vào thấp. | **Thấp**: Chi phí cố định theo số lượng metric được cấu hình trước từ đầu. |
| **Giải pháp kiểm soát (Mitigation)** | **Chiến lược Quét Giới hạn & Tối ưu Shard**: <br>1. Thiết lập chính sách giới hạ dữ liệu chặt chẽ (`time > ago(2h)`), tận dụng vùng Memory Store của Timestream.<br>2. Cấu hình số lượng Kinesis Shard vừa vặn với baseline ngày thường, sử dụng API `UpdateShardCount` để chủ động scale up ngắn hạn khi load test/event thay vì duy trì dư thừa 24/7. | Không áp dụng vì đã bị loại do **Độ trễ (Batching Latency)** không đáp ứng được Lead time ≥ 15 phút. | Không áp dụng vì bị loại do **Data Down-sampling** (mất độ phân giải sau 15 ngày, không học được slow drift). |

* **Trade-off chấp nhận:** Để đổi lấy độ phân giải dữ liệu hoàn hảo (Real-time granularity) lưu trữ trọn vẹn trong 90 ngày và tốc độ truy vấn tức thời phục vụ AI Engine, nhóm chấp nhận độ phức tạp cao hơn trong việc quản lý, tối ưu hóa đồng thời **Chi phí đẩy dữ liệu (PUT Payload Units) trên Kinesis Data Streams** và **Chi phí Quét Truy vấn (Query Scan Cost) trên Amazon Timestream**. 

  Nhóm sẽ thực hiện cấu hình **Magnetic Store Writes** nhằm tối ưu hóa chi phí ghi trực tiếp vào Timestream, đồng thời thiết lập chính sách giới hạn chặt chẽ (gắn cố định filter `time > ago(2h)`) cho các câu lệnh truy vấn của mô hình dự báo. Điều này đảm bảo hệ thống vừa giữ vững mục tiêu kỹ thuật nghiêm ngặt (FP ≤ 12%, Catch ≥ 80% drift), vừa kiểm soát tổng chi phí vận hành thực tế không vượt quá mức giới hạn circuit breaker $200/tháng đề ra.
---

## 4. Constraints

- **AWS only** – Không triển khai multi-cloud, chỉ sử dụng các dịch vụ AWS.
- **Region** – ap-southeast-1 (Singapore) cho toàn bộ môi trường triển khai.
- **Budget cap** – ≤ $200/tháng cho solution capstone.
- **Single-region deployment** – Không triển khai multi-region, Disaster Recovery chỉ ở mức thiết kế.
- **Auto-remediation** – Không nằm trong phạm vi dự án; hệ thống chỉ thực hiện prediction và recommendation.
- **Auto-retraining pipeline** – Không xây dựng trong capstone; chỉ mô tả trigger logic thông qua ADR.
- **Infrastructure metrics only** – Chỉ xử lý metrics hạ tầng (CPU, Memory, Queue Depth, Connections, Latency), không xử lý business metrics hoặc dữ liệu PII.
- **Synthetic workload only** – Không sử dụng production traffic; kiểm thử bằng k6/Locust và dữ liệu mô phỏng.
- **LLM-based prediction** – Không sử dụng do chi phí cao; tập trung vào statistical/ML-based forecasting.
- **Code freeze**: Đóng băng code vào 08:00 AM ngày 02/07/2026. Mọi thay đổi sau thời điểm này đều bị từ chối.

---

## 5. Open questions

- [ ] Q1: Tier-1 services nào sẽ được lựa chọn làm baseline services trong giai đoạn capstone?
- [ ] Q2: Lead time mục tiêu 15 phút có áp dụng đồng đều cho tất cả service hay có ngoại lệ cho RDS-intensive workloads?
- [ ] Q3: Baseline refresh nên thực hiện theo lịch cố định hàng tuần hay dựa trên drift threshold?
- [ ] Q4: Capacity recommendation có yêu cầu approval workflow trước khi gửi SNS notification hay không?
- [ ] Q5: Service onboarding cần tối thiểu bao nhiêu ngày historical metrics để baseline đạt chất lượng chấp nhận được?