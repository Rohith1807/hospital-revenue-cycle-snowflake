# Hospital Revenue Cycle & Clinical Analysis Pipeline 🏥


**Tech Stack:** Snowflake Data Cloud, SQL, Tasks, Stored Procedures, Python (Data Profiling)  
**Domain:** Healthcare Revenue Cycle Management (RCM)

## 📋 Executive Summary

This project implements an end-to-end ELT (Extract, Load, Transform) pipeline in Snowflake to analyze hospital financial performance. Using raw claims data from FinThrive, I architected a Medallion Architecture to transform disjointed claims, payment, and clinical data into actionable insights regarding **Revenue Leakage**, **Payer Efficiency**, and **Clinical Quality**.

The system automates weekly reporting via Snowflake Tasks and utilizes Materialized Views to accelerate dashboard performance for executive leadership.

---

## 🚀 Key Strategic Findings

### 1. Financial Operations (Cash Flow)
* **32.3 Day Payment Lag:** Analysis of the Northeast Region revealed a 32-day average collection cycle. While efficient, this region carries the highest volume of revenue ($1.6M), making any slippage critical.
* **$1.1 Million Data Governance Risk:** Identified $1.1M in revenue (approx. 40% of total) linked to facilities with an "Unknown" region. This highlights a critical Master Data Management (MDM) gap requiring immediate remediation.
* **0.2% vs. 100% Volatility:** Trend analysis exposed massive volatility, ranging from a near-zero collection rate in Feb 2022 (due to high-value denials) to 100% in May 2023 (instant self-pay settlements).

### 2. Clinical Profitability & Risk
* **Oncology vs. Sepsis:**
    * **Profit Driver:** Oncology (`Z51.11`) is the highest margin service line, generating $224k per case.
    * **Revenue Leakage:** Identified 6 cases of Sepsis with $0.00 payment, indicating likely clinical documentation failures or audit denials.
* **"Failure Demand" Cost:** 40% of the top revenue-generating diagnosis codes were related to Orthopedic Complications (`T84`). While profitable (~$33k/case), these represent negative quality outcomes (implants breaking/infected).

### 3. Advanced Quality Analytics (Readmissions)
* **0-Day Readmission Flags:** Implemented advanced SQL Window Functions (`LAG`) to identify patients with multiple admissions on the same day. These "0-Day" flags successfully detected interim billing transfers and potential split-billing compliance risks.

---

## 🏗️ Technical Architecture

I implemented a Tiered Governance Architecture to separate raw ingestion from business logic.

| Layer | Schema | Description |
| :--- | :--- | :--- |
| **Raw** | `HOSPITAL_CLAIMS_DATA.ISTG` | Read-only source system (FinThrive Marketplace). |
| **Curation** | `BISON_DB.CUR_HOSPITAL_CLAIMS` | **Cleaned & Enriched.** Handles NULLs, standardizes Payer Names (CASE logic), and calculates `Days_To_Pay`. |
| **Aggregation** | `BISON_DB.AGG_FINANCIALS` | **Business Ready.** Contains KPIs, Summary Views, and Materialized Views for reporting. |

### Key Features Implemented:
* **Data Governance:** Utilized Semantic Tagging (`SET TAG ... = 'FinThrive_Analysis'`) at the Schema level to ensure 100% governance inheritance for all downstream objects.
* **Automation:** Deployed a Snowflake Task (`WEEKLY_CLINICAL_REPORT_TASK`) to execute a Stored Procedure every Sunday at 4:00 AM CST.
* **Performance:** Built Materialized Views (`MV_TOP_PERFORMING_REGIONS`) to pre-compute heavy aggregations, reducing query latency for regional dashboards.
* **User Abstraction:** Developed User-Defined Table Functions (UDTFs) to allow non-technical users to query regional stats and CPT codes without writing SQL.

---

## 📊 Data Logic (Mini-Catalog)

| Field | Logic / Formula | Business Value |
| :--- | :--- | :--- |
| `DAYS_TO_PAY` | `DATEDIFF(day, BILLEDDATE, LAST_PAYMENT_DATE)` | Measures RCM velocity and cash flow bottlenecks. |
| `IS_HIGH_VALUE` | `IFF(TOTALCHARGES > 50000, 'YES', 'NO')` | Flags the top 5% of claims that drive 50% of audit risk. |
| `PAYER_CATEGORY` | `CASE WHEN...` | Groups 100+ raw payer names into buckets (Medicare, Commercial, BCBS). |
| `READMISSION_FLAG`| `LAG(ADMISSION_DATE) OVER (PARTITION BY PATIENT)` | Identifies patients returning within 30 days (Quality Penalty Risk). |

---
## Dashboard
<img width="1543" height="807" alt="Screenshot 2025-12-06 134306" src="https://github.com/user-attachments/assets/a43cc19e-9ab2-4360-b32e-b65ea7d98cd8" />

---

## 🛠️ How to Run This Project

- "Note: The scripts reference a database named BISON_DB. Please find and replace this with your own database name before running."
- load the script into the snowflake and run the script. the script is divided into worksheets and each worksheet explains what it perform. 

---

*Disclaimer: Data source provided via Snowflake Marketplace (FinThrive Healthcare). All data is de-identified and used for educational/analytical purposes.*
