-----------------------------------------------------------
-----------------------------------------------------------
-- WORKSHEET 1: CURATION LAYER 
-----------------------------------------------------------
-----------------------------------------------------------

/* 
This code establishes a Curation Layer (CUR_HOSPITAL_CLAIMS) by joining raw claims, payments, and facility data into a single enriched table, standardizing payer names, handling nulls, and calculating critical financial metrics like "Days to Pay" and "High Value" flags.

Result Analysis: The execution creates a clean, analytical base table that reveals a significant revenue cycle lag and identifies high-risk financial outliers (claims >$50k).
*/

-- 1. Set the Context to use my own database

USE ROLE TRAINING_ROLE;
CREATE WAREHOUSE IF NOT EXISTS BISON_WH;
USE WAREHOUSE BISON_WH;
CREATE DATABASE IF NOT EXISTS BISON_DB;
USE BISON_DB.PUBLIC;

-- 2. Create the Schema INSIDE BISON_DB

CREATE OR REPLACE SCHEMA BISON_DB.CUR_HOSPITAL_CLAIMS;

-- 3. Create the Tag
CREATE OR REPLACE TAG BISON_DB.CUR_HOSPITAL_CLAIMS.PROJECT
    COMMENT = 'Tag for Project Objects';

-- 4. Applying Tag to Schema
-- Applying to the Schema ensures all the future tables inside inherit this tag automatically

ALTER SCHEMA BISON_DB.CUR_HOSPITAL_CLAIMS
    SET TAG BISON_DB.CUR_HOSPITAL_CLAIMS.PROJECT = 'FinThrive_Analysis';

-- 4. Create the Curated Table (Writing to BISON_DB, Reading from HOSPITAL_CLAIMS_DATA)
CREATE OR REPLACE TABLE BISON_DB.CUR_HOSPITAL_CLAIMS.CUR_ENRICHED_CLAIMS AS
WITH EOB_FINANCIALS AS (
  -- pre-aggregating payments to handle multiple checks per claim
    SELECT 
        CLAIMID, 
        SITEID, 
        SUM(PAIDAMOUNT) AS TOTAL_PAID_AMOUNT,
        SUM(BILLEDAMOUNT) AS TOTAL_BILLED_AMOUNT,
        MAX(PAYMENTDATE) AS LAST_PAYMENT_DATE
    FROM HOSPITAL_CLAIMS__REMITS_DATA.ISTG.EOBDETAIL
    GROUP BY CLAIMID, SITEID
)
SELECT 
    cd.CLAIMID,
    cd.SITEID,
    -- logic 1: Standardize (CASE Statements) --> Group 100+ raw names into 5 categories.
    CASE 
        WHEN LEN(TRIM(COALESCE(cd.PAYERPRIMARYNAME, ''))) = 0 THEN 'Unspecified Payer'
        WHEN UPPER(cd.PAYERPRIMARYNAME) LIKE '%MEDICARE%' THEN 'Medicare'
        WHEN UPPER(cd.PAYERPRIMARYNAME) LIKE '%MEDICAID%' THEN 'Medicaid'
        WHEN UPPER(cd.PAYERPRIMARYNAME) LIKE '%BLUE%' OR UPPER(cd.PAYERPRIMARYNAME) LIKE '%BCBS%' THEN 'BCBS'
        WHEN UPPER(cd.PAYERPRIMARYNAME) LIKE '%UNITED%' THEN 'UnitedHealthcare'
        WHEN UPPER(cd.PAYERPRIMARYNAME) LIKE '%CIGNA%' THEN 'Cigna'
        WHEN UPPER(cd.PAYERPRIMARYNAME) LIKE '%AETNA%' THEN 'Aetna'
        ELSE 'Other Commercial'
    END AS PAYER_CATEGORY,
    
    cd.STMFROM AS ADMISSION_DATE,
    cd.STMTHRU AS DISCHARGE_DATE,

    -- Logic 2: Calculate Length of Stay (DATEDIFF) -> Critical for measuring hospital efficiency.
    DATEDIFF(day, cd.STMFROM, COALESCE(cd.STMTHRU, cd.STMFROM)) AS LENGTH_OF_STAY,
    
    -- Logic 3: Handle Null Financials (COALESCE) -> Prevents math errors by turning NULLs into 0.00.
    COALESCE(eob.TOTAL_BILLED_AMOUNT, cd.TOTALCHARGES, 0) AS BILLED_AMOUNT,
    COALESCE(eob.TOTAL_PAID_AMOUNT, 0) AS PAID_AMOUNT,

    -- Logic 4: Revenue Cycle Speed (DATEDIFF across tables) -> Measures how fast insurance pays.
    DATEDIFF(day, cd.BILLEDDATE, eob.LAST_PAYMENT_DATE) AS DAYS_TO_PAY,

    -- Logic 5: Region Fill (COALESCE) -> Ensures we don't lose data just because Region is blank and also bed count.
    COALESCE(fd.REGION, 'Unknown') AS HOSPITAL_REGION,
    COALESCE(fd.BEDSIZE, 0) AS HOSPITAL_BED_COUNT,

    -- Logic 6: High Value Flag (IFF) -> Instantly identifies catastrophic/expensive claims.
    IFF(COALESCE(eob.TOTAL_BILLED_AMOUNT, cd.TOTALCHARGES, 0) > 50000, 'YES', 'NO') AS IS_HIGH_VALUE_CLAIM

FROM HOSPITAL_CLAIMS__REMITS_DATA.ISTG.CLAIMDETAIL cd
LEFT JOIN EOB_FINANCIALS eob 
    ON cd.CLAIMID = eob.CLAIMID 
    AND cd.SITEID = eob.SITEID
LEFT JOIN HOSPITAL_CLAIMS__REMITS_DATA.ISTG.FACILITYDETAIL fd
    ON cd.PROVIDERID = fd.PROVIDERID;

-- select * from CUR_ENRICHED_CLAIMS
-- LIMIT 25;

-----------------------------------------------------------
-----------------------------------------------------------
-- WORKSHEET 2: STORED PROCEDURE
-----------------------------------------------------------
-----------------------------------------------------------

/*
This stored procedure automates clinical financial analysis by aggregating total revenue against primary diagnosis codes to identify top revenue drivers, while simultaneously isolating conditions with zero reimbursement into a specialized "Watchlist" for denial mitigation.

Result Analysis
The execution produces two critical datasets: a Profitability Report that reveals which clinical conditions generate the most cash, and a Risk Watchlist that exposes specific diagnoses where the hospital is treating patients but getting paid $0, highlighting urgent targets for the Revenue Cycle team.

*/

CREATE OR REPLACE PROCEDURE BISON_DB.CUR_HOSPITAL_CLAIMS.PROC_GENERATE_CLINICAL_REPORT()
RETURNS STRING
LANGUAGE SQL
AS
$$
BEGIN
    -- Transformation 1: Join Diagnosis + Revenue to find most profitable conditions
    
    CREATE OR REPLACE TABLE BISON_DB.CUR_HOSPITAL_CLAIMS.REPORT_TOP_DIAGNOSES AS
    SELECT 
        d.DIAGCODE,
        COUNT(DISTINCT d.CLAIMID) AS CASE_VOLUME,
        SUM(c.PAID_AMOUNT) AS TOTAL_REVENUE
    FROM HOSPITAL_CLAIMS__REMITS_DATA.ISTG.DIAGNOSISDETAIL d
    JOIN BISON_DB.CUR_HOSPITAL_CLAIMS.CUR_ENRICHED_CLAIMS c 
        ON d.CLAIMID = c.CLAIMID AND d.SITEID = c.SITEID
    WHERE d.SEQUENCE = 1
    GROUP BY d.DIAGCODE
    ORDER BY TOTAL_REVENUE DESC;

    -- Transformation 2: Create a 'Watchlist' for conditions that pay $0 (Denial Risks)
    
    CREATE OR REPLACE TABLE BISON_DB.CUR_HOSPITAL_CLAIMS.WATCHLIST_ZERO_PAYMENT AS
    SELECT DIAGCODE, CASE_VOLUME 
    FROM BISON_DB.CUR_HOSPITAL_CLAIMS.REPORT_TOP_DIAGNOSES
    WHERE TOTAL_REVENUE = 0;

    RETURN 'Success: Clinical Report and Watchlist Tables Created.';
END;
$$;

-- to verify it works
CALL BISON_DB.CUR_HOSPITAL_CLAIMS.PROC_GENERATE_CLINICAL_REPORT();

-- SELECT * FROM REPORT_TOP_DIAGNOSES LIMIT 10;

-- SELECT * FROM WATCHLIST_ZERO_PAYMENT
-- ORDER BY CASE_VOLUME DESC
-- LIMIT 10;

-----------------------------------------------------------
-----------------------------------------------------------
-- WORKSHEET 3: AGGREGATION
-----------------------------------------------------------
-----------------------------------------------------------

-- STEP 1: 
-- Create Schema & Tag
CREATE OR REPLACE SCHEMA BISON_DB.AGG_FINANCIALS;
ALTER SCHEMA BISON_DB.AGG_FINANCIALS 
    SET TAG BISON_DB.CUR_HOSPITAL_CLAIMS.PROJECT = 'FinThrive_Analysis';

-- Create 4 Different Tables/Views with 4 Aggregation Types

-- Object 1 (Table): Regional Performance
-- Aggregations Used: COUNT, AVG, SUM
-- OBJECT 1 (Table): Regional Performance 
CREATE OR REPLACE TABLE BISON_DB.AGG_FINANCIALS.REGIONAL_PERFORMANCE AS
SELECT 
    HOSPITAL_REGION,
    COUNT(CLAIMID) AS TOTAL_CLAIMS,
    
    -- If Avg is Null (No payments yet), show 0
    COALESCE(ROUND(AVG(DAYS_TO_PAY), 1), 0) AS AVG_DAYS_TO_PAY,
    
    SUM(PAID_AMOUNT) AS TOTAL_REVENUE
FROM BISON_DB.CUR_HOSPITAL_CLAIMS.CUR_ENRICHED_CLAIMS
GROUP BY HOSPITAL_REGION;

/*
I used COALESCE on the 'Average Days to Pay' metric because some regions (like the West) had pending claims with no payment dates yet. Leaving them as NULL would break the dashboard visualizations, so I defaulted them to 0 to indicate 'No Historical Payment Data'.

I decided to keep the 'Unknown' region in my aggregation layer rather than filtering it out. This decision ensures transparency, allowing stakeholders to see that ~40% of our claims are missing facility data, which is a critical data governance finding
*/


-- Object 2 (View): Monthly Payment Trends
-- Aggregations Used: SUM
CREATE OR REPLACE VIEW BISON_DB.AGG_FINANCIALS.PAYMENT_TRENDS AS
SELECT 
    DATE_TRUNC('month', ADMISSION_DATE) AS SERVICE_MONTH,
    SUM(BILLED_AMOUNT) AS BILLED,
    SUM(PAID_AMOUNT) AS COLLECTED
FROM BISON_DB.CUR_HOSPITAL_CLAIMS.CUR_ENRICHED_CLAIMS
GROUP BY 1;

-- Object 3 (View): Top Procedures
-- Aggregations Used: COUNT
CREATE OR REPLACE VIEW BISON_DB.AGG_FINANCIALS.TOP_CPT_CODES AS
SELECT 
    CPTCODE, 
    COUNT(*) AS FREQUENCY
FROM HOSPITAL_CLAIMS__REMITS_DATA.ISTG.CPTDETAIL
GROUP BY CPTCODE 
ORDER BY FREQUENCY DESC;

-- Object 4 (Table): High Value Claim Stats
-- Aggregations Used: MIN, MAX
CREATE OR REPLACE TABLE BISON_DB.AGG_FINANCIALS.HIGH_VALUE_SUMMARY AS
SELECT 
    IS_HIGH_VALUE_CLAIM,
    COUNT(CLAIMID) AS CLAIM_COUNT,
    MIN(BILLED_AMOUNT) AS MIN_BILL,         -- Aggregation #4: MIN
    MAX(BILLED_AMOUNT) AS MAX_BILL          -- Aggregation #5: MAX
FROM BISON_DB.CUR_HOSPITAL_CLAIMS.CUR_ENRICHED_CLAIMS
GROUP BY 1;


-- STEP 2: Create Materialized View that queries data IN Step 1
-- This MV queries 'REGIONAL_PERFORMANCE' 
-- It acts as a "Leaderboard" filtering only regions with revenue
CREATE OR REPLACE MATERIALIZED VIEW BISON_DB.AGG_FINANCIALS.MV_TOP_PERFORMING_REGIONS AS
SELECT 
    HOSPITAL_REGION,
    TOTAL_REVENUE,
    AVG_DAYS_TO_PAY
FROM BISON_DB.AGG_FINANCIALS.REGIONAL_PERFORMANCE
WHERE TOTAL_REVENUE > 0;

-- SELECT * FROM REGIONAL_PERFORMANCE;

-- select * from high_value_summary;

-- select * from payment_trends;

-- select * from top_cpt_codes;

-- select * from mv_top_performing_regions;

-----------------------------------------------------------
-----------------------------------------------------------
-- WORKSHEET 4: FUNCTION
-----------------------------------------------------------
-----------------------------------------------------------

/*
This script creates a User-Defined Table Function (UDTF) named GET_REGION_STATS that accepts a dynamic region parameter to filter the aggregated performance table, allowing users to instantly retrieve specific financial KPIs (Revenue and Payment Lag) for any target region without writing complex SQL.
*/
-- while calling this function user can specify the region name to get the results.

CREATE OR REPLACE FUNCTION BISON_DB.AGG_FINANCIALS.GET_REGION_STATS(target_region STRING)
RETURNS TABLE (Region STRING, Revenue NUMBER(38,2), Avg_Days_To_Pay NUMBER(38,1))
LANGUAGE SQL
AS
$$
    SELECT 
        HOSPITAL_REGION, 
        TOTAL_REVENUE, 
        AVG_DAYS_TO_PAY
    FROM BISON_DB.AGG_FINANCIALS.REGIONAL_PERFORMANCE
    WHERE HOSPITAL_REGION = target_region
$$;

--Test:
SELECT * FROM TABLE(BISON_DB.AGG_FINANCIALS.GET_REGION_STATS('Northeast'));


-----------------------------------------------------------
-----------------------------------------------------------
-- WORKSHEET 6: TASKS
-----------------------------------------------------------
-----------------------------------------------------------

/*
This code creates and schedules an automated Snowflake Task named WEEKLY_CLINICAL_REPORT_TASK to execute the clinical stored procedure every Sunday at 4:00 AM Central Time, ensuring the "Top Diagnoses" and "Zero Payment Watchlist" tables are refreshed weekly without manual intervention.
*/


CREATE OR REPLACE TASK BISON_DB.CUR_HOSPITAL_CLAIMS.WEEKLY_CLINICAL_REPORT_TASK
    WAREHOUSE = BISON_WH
    SCHEDULE = 'USING CRON 0 4 * * SUN America/Chicago' 
AS
    CALL BISON_DB.CUR_HOSPITAL_CLAIMS.PROC_GENERATE_CLINICAL_REPORT();

-- Test then Suspend
ALTER TASK BISON_DB.CUR_HOSPITAL_CLAIMS.WEEKLY_CLINICAL_REPORT_TASK RESUME;
ALTER TASK BISON_DB.CUR_HOSPITAL_CLAIMS.WEEKLY_CLINICAL_REPORT_TASK SUSPEND;


-----------------------------------------------------------
-----------------------------------------------------------
-- WORKSHEET 5: SUMMARY
-----------------------------------------------------------
-----------------------------------------------------------
/*
1. Data Set Name & Description:
I selected the FinThrive Healthcare: Hospital Claims & Remits Data. This dataset provides a comprehensive, real-world view of the US healthcare revenue cycle, containing de-identified claims from over 500 facilities. It includes detailed financial data (billed charges, insurance payments/EOBs, denials) as well as clinical contexts (diagnosis and CPT procedure codes), allowing for deep analysis of hospital efficiency and payer reimbursement behaviors.

----------------------------------------------------------------------------------------

2. Naming Convention & Schema Structure:
I implemented architecture using prefixes to distinguish data levels: CUR_ for the Curation Schema (BISON_DB.CUR_HOSPITAL_CLAIMS), and AGG_ for the Aggregation Schema (BISON_DB.AGG_FINANCIALS). Additionally, I used MV_ to explicitly designate Materialized Views.

------------------------------------------------------------------------------------------

3. Mini Data Catalog (Logic & Formulas) In the curation layer, I used custom fields to transform raw data into actionable business intelligence:

- DAYS_TO_PAY: Calculated using DATEDIFF(day, BILLEDDATE, LAST_PAYMENT_DATE). This critical KPI measures the velocity of cash flow, identifying bottlenecks such as the specific region found to have a payment lag in the sample analysis.

- PAYER_CATEGORY: A standardized grouping field created via a CASE statement that consolidates over 100 distinct raw payer names into five analytical buckets (Medicare, Medicaid, BCBS, UnitedHealthcare, and Commercial) to enable high-level financial comparisons.

- IS_HIGH_VALUE_CLAIM: A risk flag created using IFF(TOTALCHARGES > 50000, 'YES', 'NO'). This isolates the claims that often drive over 50% of the hospital's revenue risk and audit exposure.

- LENGTH_OF_STAY: Derived via DATEDIFF between Admission and Discharge dates. This serves as a primary proxy for hospital efficiency and resource utilization.

- HOSPITAL_REGION: Implemented using COALESCE(REGION, 'Unknown') to gracefully handle the ~40% of facility records with missing geographic data, ensuring that null values do not result in dropped rows during aggregation.

*/

-------------------------------------------------------------------------------------------------
-- NEW OBJECT: Data Quality Scorecard
-- Logic: Checks how many claims are missing a payment date (Revenue Cycle "Blind Spots")
CREATE OR REPLACE VIEW BISON_DB.AGG_FINANCIALS.DATA_QUALITY_SCORECARD AS
SELECT 
    COUNT(*) AS TOTAL_CLAIMS,
    
    -- Count how many rows have NULL in the 'Days to Pay' column
    SUM(CASE WHEN DAYS_TO_PAY IS NULL THEN 1 ELSE 0 END) AS CLAIMS_MISSING_PAYMENT_DATE,
    
    -- Calculate the Percentage
    ROUND(
        (SUM(CASE WHEN DAYS_TO_PAY IS NULL THEN 1 ELSE 0 END) / COUNT(*)) * 100, 
    2) AS PCT_MISSING_PAYMENT_DATE,
    
    'Critical' AS QUALITY_FLAG
FROM BISON_DB.CUR_HOSPITAL_CLAIMS.CUR_ENRICHED_CLAIMS;

-- Test it:
SELECT * FROM BISON_DB.AGG_FINANCIALS.DATA_QUALITY_SCORECARD;

CREATE OR REPLACE FUNCTION BISON_DB.AGG_FINANCIALS.GET_TOP_CPT_BY_REGION(target_region STRING)
RETURNS TABLE (CPT_Code STRING, Frequency INT)
LANGUAGE SQL
AS
$$
    SELECT 
        cpt.CPTCODE, 
        COUNT(cpt.CPTCODE) AS FREQUENCY
    FROM HOSPITAL_CLAIMS__REMITS_DATA.ISTG.CPTDETAIL cpt
    JOIN BISON_DB.CUR_HOSPITAL_CLAIMS.CUR_ENRICHED_CLAIMS c 
        ON cpt.CLAIMID = c.CLAIMID AND cpt.SITEID = c.SITEID
    WHERE c.HOSPITAL_REGION = target_region
    GROUP BY cpt.CPTCODE
    ORDER BY FREQUENCY DESC
    LIMIT 10
$$;

-- Test: See what procedures are most common in the Northeast
SELECT * FROM TABLE(BISON_DB.AGG_FINANCIALS.GET_TOP_CPT_BY_REGION('Northeast'));

CREATE OR REPLACE FUNCTION BISON_DB.AGG_FINANCIALS.GET_DIAGNOSIS_ECONOMICS(target_diag STRING)
RETURNS TABLE (Diagnosis_Code STRING, Avg_Revenue_Per_Case NUMBER(38,2), Total_Cases INT)
LANGUAGE SQL
AS
$$
    SELECT 
        DIAGCODE, 
        -- Calculate Average (Total Revenue / Volume)
        ROUND((TOTAL_REVENUE / NULLIF(CASE_VOLUME, 0)), 2) AS AVG_REVENUE,
        CASE_VOLUME
    FROM BISON_DB.CUR_HOSPITAL_CLAIMS.REPORT_TOP_DIAGNOSES
    WHERE DIAGCODE = target_diag
$$;

-- Test: Check the financials for Sepsis or COVID (e.g., 'U071')
SELECT * FROM TABLE(BISON_DB.AGG_FINANCIALS.GET_DIAGNOSIS_ECONOMICS('U071'));

-- Which insurance payers are actually funding our hospital, and who is slow to pay
SELECT 
    PAYER_CATEGORY,
    COUNT(CLAIMID) AS TOTAL_CLAIMS,
    SUM(PAID_AMOUNT) AS TOTAL_CASH_COLLECTED,
    -- Calculate "Revenue per Claim" to see who pays the most per patient
    ROUND(SUM(PAID_AMOUNT) / COUNT(CLAIMID), 2) AS AVG_REVENUE_PER_CLAIM,
    ROUND(AVG(DAYS_TO_PAY), 0) AS AVG_LAG_DAYS
FROM BISON_DB.CUR_HOSPITAL_CLAIMS.CUR_ENRICHED_CLAIMS
GROUP BY 1
ORDER BY 3 DESC;


-- Which region is hurting our cash flow the most?
SELECT 
    HOSPITAL_REGION,
    TOTAL_REVENUE,
    AVG_DAYS_TO_PAY
FROM BISON_DB.AGG_FINANCIALS.MV_TOP_PERFORMING_REGIONS
ORDER BY AVG_DAYS_TO_PAY DESC; -- Worst regions at the top


-- What medical conditions are keeping the lights on?
SELECT 
    DIAGCODE,
    CASE_VOLUME,
    TOTAL_REVENUE,
    -- Calculate "Value per Case"
    ROUND(TOTAL_REVENUE / CASE_VOLUME, 2) AS AVG_VALUE_PER_CASE
FROM BISON_DB.CUR_HOSPITAL_CLAIMS.REPORT_TOP_DIAGNOSES
ORDER BY TOTAL_REVENUE DESC
LIMIT 10;


-- Where are we working for free
SELECT * FROM BISON_DB.CUR_HOSPITAL_CLAIMS.WATCHLIST_ZERO_PAYMENT
ORDER BY CASE_VOLUME DESC
LIMIT 10;


-- Is our financial health getting better or worse
SELECT 
    SERVICE_MONTH,
    BILLED,
    COLLECTED,
    -- Calculate Collection Rate %
    ROUND((COLLECTED / NULLIF(BILLED, 0)) * 100, 1) AS COLLECTION_RATE
FROM BISON_DB.AGG_FINANCIALS.PAYMENT_TRENDS
WHERE SERVICE_MONTH >= '2022-01-01'
ORDER BY 1;

-- modified worksheet 1 for making some advanced analysis.
-----------------------------------------------------------
-- WORKSHEET 1: CURATION LAYER (UPDATED WITH PATIENT KEY)
-----------------------------------------------------------
USE ROLE TRAINING_ROLE;
USE WAREHOUSE BISON_WH;
USE DATABASE BISON_DB; 

CREATE OR REPLACE TABLE BISON_DB.CUR_HOSPITAL_CLAIMS.CUR_ENRICHED_CLAIMS AS
WITH EOB_FINANCIALS AS (
    SELECT 
        CLAIMID, 
        SITEID, 
        SUM(PAIDAMOUNT) AS TOTAL_PAID_AMOUNT,
        SUM(BILLEDAMOUNT) AS TOTAL_BILLED_AMOUNT,
        MAX(PAYMENTDATE) AS LAST_PAYMENT_DATE
    FROM HOSPITAL_CLAIMS__REMITS_DATA.ISTG.EOBDETAIL
    GROUP BY CLAIMID, SITEID
)
SELECT 
    cd.CLAIMID,
    cd.SITEID,
    
    -- NEW: Added Patient Key for Advanced Analysis
    cd.PATIENT_KEY, 

    CASE 
        WHEN LEN(TRIM(COALESCE(cd.PAYERPRIMARYNAME, ''))) = 0 THEN 'Unspecified Payer'
        WHEN UPPER(cd.PAYERPRIMARYNAME) LIKE '%MEDICARE%' THEN 'Medicare'
        WHEN UPPER(cd.PAYERPRIMARYNAME) LIKE '%MEDICAID%' THEN 'Medicaid'
        WHEN UPPER(cd.PAYERPRIMARYNAME) LIKE '%BLUE%' OR UPPER(cd.PAYERPRIMARYNAME) LIKE '%BCBS%' THEN 'BCBS'
        WHEN UPPER(cd.PAYERPRIMARYNAME) LIKE '%UNITED%' THEN 'UnitedHealthcare'
        WHEN UPPER(cd.PAYERPRIMARYNAME) LIKE '%CIGNA%' THEN 'Cigna'
        WHEN UPPER(cd.PAYERPRIMARYNAME) LIKE '%AETNA%' THEN 'Aetna'
        ELSE 'Other Commercial'
    END AS PAYER_CATEGORY,
    
    cd.STMFROM AS ADMISSION_DATE,
    cd.STMTHRU AS DISCHARGE_DATE,
    
    DATEDIFF(day, cd.STMFROM, COALESCE(cd.STMTHRU, cd.STMFROM)) AS LENGTH_OF_STAY,
    
    COALESCE(eob.TOTAL_BILLED_AMOUNT, cd.TOTALCHARGES, 0) AS BILLED_AMOUNT,
    COALESCE(eob.TOTAL_PAID_AMOUNT, 0) AS PAID_AMOUNT,
    
    DATEDIFF(day, cd.BILLEDDATE, eob.LAST_PAYMENT_DATE) AS DAYS_TO_PAY,
    
    COALESCE(fd.REGION, 'Unknown') AS HOSPITAL_REGION,
    COALESCE(fd.BEDSIZE, 0) AS HOSPITAL_BED_COUNT,
    
    IFF(COALESCE(eob.TOTAL_BILLED_AMOUNT, cd.TOTALCHARGES, 0) > 50000, 'YES', 'NO') AS IS_HIGH_VALUE_CLAIM

FROM HOSPITAL_CLAIMS__REMITS_DATA.ISTG.CLAIMDETAIL cd
LEFT JOIN EOB_FINANCIALS eob 
    ON cd.CLAIMID = eob.CLAIMID 
    AND cd.SITEID = eob.SITEID
LEFT JOIN HOSPITAL_CLAIMS__REMITS_DATA.ISTG.FACILITYDETAIL fd
    ON cd.PROVIDERID = fd.PROVIDERID;

-- ADVANCED ANALYSIS: 30-Day Readmission Risk
SELECT 
    PATIENT_KEY,
    ADMISSION_DATE AS CURRENT_VISIT,
    LAG(ADMISSION_DATE) OVER (PARTITION BY PATIENT_KEY ORDER BY ADMISSION_DATE) AS PREVIOUS_VISIT,
    DATEDIFF(day, LAG(ADMISSION_DATE) OVER (PARTITION BY PATIENT_KEY ORDER BY ADMISSION_DATE), ADMISSION_DATE) AS DAYS_SINCE_LAST_VISIT,
    CASE 
        WHEN DATEDIFF(day, LAG(ADMISSION_DATE) OVER (PARTITION BY PATIENT_KEY ORDER BY ADMISSION_DATE), ADMISSION_DATE) <= 30 
        THEN 'Readmission Risk' 
        ELSE 'New Episode' 
    END AS READMISSION_FLAG
FROM BISON_DB.CUR_HOSPITAL_CLAIMS.CUR_ENRICHED_CLAIMS
ORDER BY PATIENT_KEY, ADMISSION_DATE;