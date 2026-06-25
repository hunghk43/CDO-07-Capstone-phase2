# Test & Evaluation Report - Task Force 4 · CDO-07

<!-- Doc owner: Nhóm CDO7
     Status: Draft (W11 T3-T4) → Final (W12 T4 Pack #2)
     Word target: 1000-1800 từ -->

## 1. Test coverage

| Test type              | Tool             | Coverage / Scope                                  |
| ---------------------- | ---------------- | ------------------------------------------------- |
| Unit test              | Pytest           | AI inference modules, validation logic            |
| Integration test       | Postman / Pytest | Tenant onboarding flow, AI API integration        |
| End-to-End test        | k6               | Drift detection → Prediction → Grafana annotation |
| Load test              | k6               | Sustained 100 RPS trong 10 phút                   |
| Chaos test             | Manual           | 3 curveball scenarios                             |
| Security test          | Trivy, Checkov   | Container image và Infrastructure as Code         |
| Multi-tenant isolation | Custom scripts   | Cross-service access validation                   |

## 2. SLO evidence

| SLO                    | Target   | Measured | Window               | Pass/Fail |
| ---------------------- | -------- | -------- | -------------------- | --------- |
| Platform availability  | ≥ 99.5%  | X%       | 2 weeks build period | ✓/✗       |
| AI Engine P99 latency  | < 500ms  | Xms      | Last 24h             | ✓/✗       |
| End-to-end P99 latency | < 1000ms | Xms      | Last 24h             | ✓/✗       |
| Error rate             | < 0.5%   | X%       | Last 24h             | ✓/✗       |
| Prediction lead time   | ≥ 15 min | X min    | Test scenarios       | ✓/✗       |
| Service onboarding     | < 30 min | X min    | 3 test services      | ✓/✗       |

### 2.1 SLO breach analysis

Nếu có SLO không đạt, nguyên nhân gốc rễ và biện pháp khắc phục sẽ được ghi nhận tại đây.

> TODO W12: Điền kết quả thực tế sau khi hoàn thành test suite.

## 3. Load test results

### 3.1 Test setup

* **Tool:** k6
* **Load profile:** Ramp-up từ 0 → 100 RPS trong 5 phút, duy trì 100 RPS trong 10 phút
* **Services simulated:** payment-gateway, kyc-service, reporting-api
* **Workload:** Synthetic telemetry với gradual drift và sudden spike patterns

### 3.2 Results

| Metric                 | Target    | Achieved |
| ---------------------- | --------- | -------- |
| Sustained throughput   | 100 RPS   | X        |
| AI Engine P99 latency  | < 500ms   | Xms      |
| End-to-end P99 latency | < 1500ms  | Xms      |
| Error rate             | < 1%      | X%       |
| Auto-scale triggered   | ≥ 3 tasks | ✓/✗      |

### 3.3 Bottleneck identified

* Compute bottleneck: ...
* Database bottleneck: ...
* Streaming bottleneck: ...

> TODO W12: Ghi nhận thành phần giới hạn hiệu năng cao nhất.

## 4. Prediction evaluation

| Scenario         | Description                          | Lead time | Result |
| ---------------- | ------------------------------------ | --------- | ------ |
| Gradual drift    | CPU tăng từ 40% → 95% trong 2 giờ    | X min     | ✓/✗    |
| Sudden spike     | Traffic tăng 3× trong 10 phút        | X min     | ✓/✗    |
| Slow memory leak | Memory tăng đều theo thời gian       | X min     | ✓/✗    |
| Noisy baseline   | Dao động ngẫu nhiên không phải drift | FP check  | ✓/✗    |

### Summary

* Drift detection catch rate: X%
* False positive rate: X%
* Average prediction lead time: X phút

## 5. Security validation

### 5.1 Security tests

* [ ] API authentication bypass
* [ ] Cross-tenant access attempt
* [ ] Invalid schema validation
* [ ] IAM privilege escalation
* [ ] Secret leakage through logs

### 5.2 Vulnerability scanning

| Category          | Result  |
| ----------------- | ------- |
| Container scan    | Trivy   |
| IaC scan          | Checkov |
| Critical findings | 0       |
| High findings     | X       |
| Mitigated         | ✓/✗     |

### 5.3 API contract validation

| Test case            | Expected code | Result |
| -------------------- | ------------- | ------ |
| Invalid payload      | 422           | ✓/✗    |
| Unauthorized request | 401           | ✓/✗    |
| Rate limit exceeded  | 429           | ✓/✗    |
| Service unavailable  | 503           | ✓/✗    |

## 6. Multi-tenant isolation test

| Test                                 | Expected Result | Actual Result |
| ------------------------------------ | --------------- | ------------- |
| Service A truy cập dữ liệu Service B | 403 Forbidden   | ✓/✗           |
| Cross-service metric injection       | Reject request  | ✓/✗           |
| TSDB query không có tenant filter    | Empty/Error     | ✓/✗           |
| Cross-service S3 access              | AccessDenied    | ✓/✗           |

**Kết quả:** Không phát hiện data leakage giữa các tenants.

## 7. Failure analysis

### 7.1 Failures encountered

| # | Failure | Root cause | Fix | Time to fix |
| - | ------- | ---------- | --- | ----------- |
| 1 | ...     | ...        | ... | X giờ       |
| 2 | ...     | ...        | ... | X giờ       |

### 7.2 Test gaps

* Gap 1: ...
* Gap 2: ...
* Gap 3: ...

## 8. Cost validation

Kết quả load test được đối chiếu với các giả định chi phí trong `05_cost_analysis.md`.

| Assumption                            | Status |
| ------------------------------------- | ------ |
| Monthly cost < $200                   | ✓/✗    |
| Kinesis throughput within estimate    | ✓/✗    |
| Timestream query scan within estimate | ✓/✗    |
| AWS Budget alert not triggered        | ✓/✗    |

> TODO W12: Điền số liệu thực tế từ Cost Explorer và AWS Budgets.

## Related documents

* `01_requirements_analysis.md` - NFR và SLO targets
* `02_infra_design.md` - Kiến trúc hạ tầng và scaling strategy
* `03_security_design.md` - Security controls và IAM model
* `05_cost_analysis.md` - Cost model và optimization strategy
* `08_ai_api_contract.md` - API contract và SLA definitions
* `../../ai/docs/04_eval_report.md` - AI evaluation metrics
