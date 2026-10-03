/* =====================================================================
   FinTech Risk & Transaction Analytics
   MySQL 8.0  |  Database: fintech_risk_analytics
   ---------------------------------------------------------------------
   Business problem
     Card-fraud losses are driven by a small share of transactions.
     This project builds a normalized schema from a flat transaction
     file, then identifies where, when and how fraud concentrates, and
     tests whether those patterns work as a review rule.

   Source data
     Kaggle "Credit Card Transactions Fraud Detection" (kartik2112)
     fraudTrain.csv + fraudTest.csv, combined into one dataset
     1,852,394 transactions | 999 customers | 700 merchants
     Data is synthetic; see "Limitations" at the end of this file.

   Contents
     1. Schema
     2. Load (staging)
     3. Populate normalized tables
     4. Validation checks
     5. Indexes and performance
     6. Analysis (A1 - A11)
     7. Appendix: window-function examples
     8. Limitations
   ===================================================================== */


/* =====================================================================
   1. SCHEMA
   Star-style design: transactions (fact) -> customers, merchants (dims)
   ===================================================================== */

CREATE DATABASE IF NOT EXISTS fintech_risk_analytics;
USE fintech_risk_analytics;

-- Staging: exact landing zone for the raw CSV (flat, denormalized).
-- Note: 'long' is a reserved word in MySQL, so coordinates are named
-- latitude / longitude.
CREATE TABLE staging_transactions (
    trans_date_trans_time DATETIME,
    cc_num                BIGINT,          -- 16-digit card number: BIGINT, never FLOAT
    merchant              VARCHAR(150),
    category              VARCHAR(50),
    amt                   DECIMAL(10,2),
    first_name            VARCHAR(50),
    last_name             VARCHAR(50),
    gender                CHAR(1),
    street                VARCHAR(150),
    city                  VARCHAR(100),
    state                 VARCHAR(2),
    zip                   VARCHAR(10),     -- VARCHAR keeps leading zeros
    latitude              DECIMAL(9,6),
    longitude             DECIMAL(9,6),
    city_pop              INT,
    job                   VARCHAR(150),
    dob                   DATE,
    trans_num             VARCHAR(40) PRIMARY KEY,
    unix_time             BIGINT,
    merch_lat             DECIMAL(9,6),
    merch_long            DECIMAL(9,6),
    is_fraud              TINYINT          -- 1 = fraud, 0 = legitimate
);

-- Dimension: one row per cardholder
CREATE TABLE customers (
    cc_num     BIGINT PRIMARY KEY,
    first_name VARCHAR(50),
    last_name  VARCHAR(50),
    gender     CHAR(1),
    street     VARCHAR(150),
    city       VARCHAR(100),
    state      VARCHAR(2),
    zip        VARCHAR(10),
    latitude   DECIMAL(9,6),
    longitude  DECIMAL(9,6),
    city_pop   INT,
    job        VARCHAR(150),
    dob        DATE
);

-- Dimension: one row per merchant + category
-- Surrogate key (merchant_id) because a name/coordinate natural key is
-- slow to join on and not guaranteed unique.
CREATE TABLE merchants (
    merchant_id   INT AUTO_INCREMENT PRIMARY KEY,
    merchant_name VARCHAR(150),
    category      VARCHAR(50),
    merch_lat     DECIMAL(9,6),
    merch_long    DECIMAL(9,6)
);

-- Fact: one row per transaction
CREATE TABLE transactions (
    trans_num             VARCHAR(40) PRIMARY KEY,
    trans_date_trans_time DATETIME,
    cc_num                BIGINT,
    merchant_id           INT,
    amt                   DECIMAL(10,2),
    unix_time             BIGINT,
    is_fraud              TINYINT,
    FOREIGN KEY (cc_num)      REFERENCES customers(cc_num),
    FOREIGN KEY (merchant_id) REFERENCES merchants(merchant_id)
);


/* =====================================================================
   2. LOAD (STAGING)
   Both CSVs load into the same staging table (fraudTrain first, then
   fraudTest, which appends).

   Notes from the load:
   - The CSVs carry an unnamed pandas index as the first column;
     @row_index absorbs and discards it.
   - Dates are ISO format (YYYY-MM-DD HH:MM:SS) in the raw file, even
     though Excel displays them as DD-MM-YYYY. Excel also truncates
     display at 1,048,576 rows, so fraudTrain's true size
     (1,296,675) is larger than what Excel shows.
   - Files sit in MySQL's Uploads folder (secure_file_priv).
   - Large loads can outlast the Workbench client timeout; the load keeps
     running on the server. Raise Edit > Preferences > SQL Editor >
     "DBMS connection read timeout" (e.g. 600) and check SHOW PROCESSLIST.
   ===================================================================== */

LOAD DATA INFILE 'C:/ProgramData/MySQL/MySQL Server 8.0/Uploads/fraudTrain.csv'
INTO TABLE staging_transactions
FIELDS TERMINATED BY ','
ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 ROWS
(@row_index, @trans_date_trans_time, cc_num, merchant, category, amt,
 first_name, last_name, gender, street, city, state, zip,
 @latitude, @longitude, city_pop, job, @dob, trans_num, unix_time,
 merch_lat, merch_long, is_fraud)
SET
    trans_date_trans_time = STR_TO_DATE(@trans_date_trans_time, '%Y-%m-%d %H:%i:%s'),
    latitude  = @latitude,
    longitude = @longitude,
    dob       = STR_TO_DATE(@dob, '%Y-%m-%d');

LOAD DATA INFILE 'C:/ProgramData/MySQL/MySQL Server 8.0/Uploads/fraudTest.csv'
INTO TABLE staging_transactions
FIELDS TERMINATED BY ','
ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 ROWS
(@row_index, @trans_date_trans_time, cc_num, merchant, category, amt,
 first_name, last_name, gender, street, city, state, zip,
 @latitude, @longitude, city_pop, job, @dob, trans_num, unix_time,
 merch_lat, merch_long, is_fraud)
SET
    trans_date_trans_time = STR_TO_DATE(@trans_date_trans_time, '%Y-%m-%d %H:%i:%s'),
    latitude  = @latitude,
    longitude = @longitude,
    dob       = STR_TO_DATE(@dob, '%Y-%m-%d');

-- Expected: 1,852,394 (1,296,675 train + 555,719 test)
SELECT COUNT(*) AS staging_rows FROM staging_transactions;


/* =====================================================================
   3. POPULATE NORMALIZED TABLES
   Order matters: dimensions first, then the fact table (foreign keys).
   ===================================================================== */

-- 3a. Customers: GROUP BY guarantees one row per card even if a
--     descriptive field varies across that card's transactions.
INSERT INTO customers
    (cc_num, first_name, last_name, gender, street, city, state, zip,
     latitude, longitude, city_pop, job, dob)
SELECT
    cc_num,
    MIN(first_name), MIN(last_name), MIN(gender), MIN(street), MIN(city),
    MIN(state), MIN(zip), MIN(latitude), MIN(longitude), MIN(city_pop),
    MIN(job), MIN(dob)
FROM staging_transactions
GROUP BY cc_num;                                   -- expected: 999

-- 3b. Merchants: a merchant is defined by name + category.
--     merch_lat / merch_long vary slightly per transaction in the source,
--     so one representative value is kept.
INSERT INTO merchants (merchant_name, category, merch_lat, merch_long)
SELECT merchant, category, MIN(merch_lat), MIN(merch_long)
FROM staging_transactions
GROUP BY merchant, category;                       -- expected: 700

-- 3c. Transactions: join on BOTH name and category so the join mirrors
--     how a merchant was defined in step 3b.
INSERT INTO transactions
    (trans_num, trans_date_trans_time, cc_num, merchant_id, amt, unix_time, is_fraud)
SELECT
    st.trans_num, st.trans_date_trans_time, st.cc_num, m.merchant_id,
    st.amt, st.unix_time, st.is_fraud
FROM staging_transactions st
INNER JOIN merchants m
        ON st.merchant = m.merchant_name
       AND st.category = m.category;               -- expected: 1,852,394


/* =====================================================================
   4. VALIDATION CHECKS
   ===================================================================== */

-- Row counts across all tables (1,852,394 / 999 / 700 / 1,852,394)
SELECT 'staging_transactions' AS tbl, COUNT(*) AS row_count FROM staging_transactions
UNION ALL SELECT 'customers',    COUNT(*) FROM customers
UNION ALL SELECT 'merchants',    COUNT(*) FROM merchants
UNION ALL SELECT 'transactions', COUNT(*) FROM transactions;

-- Orphaned / unmatched keys (expected: 0)
SELECT COUNT(*) AS orphaned_rows
FROM transactions
WHERE cc_num IS NULL OR merchant_id IS NULL;

-- Class balance: 1,842,743 legitimate vs 9,651 fraud (0.52%)
SELECT is_fraud, COUNT(*) AS n,
       ROUND(COUNT(*) / SUM(COUNT(*)) OVER () * 100, 3) AS pct
FROM transactions
GROUP BY is_fraud;

-- Do any merchant names exist under more than one category?
SELECT merchant_name, COUNT(*) AS versions
FROM merchants
GROUP BY merchant_name
HAVING versions > 1;

-- Cardholder age range at first transaction date (youngest is 13,
-- so age buckets must include a 0-17 group)
SELECT MIN(TIMESTAMPDIFF(YEAR, dob, '2019-01-01')) AS youngest_age FROM customers;


/* =====================================================================
   5. INDEXES AND PERFORMANCE
   The fact table has 1.85M rows and a wide VARCHAR primary key; analysis
   queries filter and group on is_fraud, cc_num, merchant_id and time.
   ===================================================================== */

CREATE INDEX idx_transactions_fraud_cc ON transactions(is_fraud, cc_num);
CREATE INDEX idx_tx_merchant_fraud     ON transactions(merchant_id, is_fraud);
CREATE INDEX idx_tx_cc_fraud           ON transactions(cc_num, is_fraud);
CREATE INDEX idx_tx_time_fraud         ON transactions(trans_date_trans_time, is_fraud);

ANALYZE TABLE transactions;

-- MySQL's default buffer pool is only 128 MB, which is far too small for
-- this table. On an 8 GB machine, 2 GB is a safe value. SET GLOBAL lasts
-- until restart; for a permanent change add this under [mysqld] in my.ini:
--     innodb_buffer_pool_size=2G
-- SET GLOBAL innodb_buffer_pool_size = 2147483648;


/* =====================================================================
   6. ANALYSIS
   Convention: fraud rate = SUM(is_fraud) / COUNT(*) * 100.
   is_fraud is a 0/1 flag, so SUM() counts frauds. Never filter fraud with
   WHERE before computing a rate, or the denominator is lost.
   ===================================================================== */

-- ---------------------------------------------------------------------
-- A1. Fraud rate by merchant category
-- Finding: online categories carry the most risk. shopping_net 1.593%,
--   misc_net 1.304%, grocery_pos 1.265%; most others are 0.15-0.4%.
-- ---------------------------------------------------------------------
SELECT
    m.category,
    COUNT(*)                                        AS total_transactions,
    SUM(t.is_fraud)                                 AS fraud_count,
    ROUND(SUM(t.is_fraud) / COUNT(*) * 100, 3)      AS fraud_rate_pct
FROM transactions t
INNER JOIN merchants m ON t.merchant_id = m.merchant_id
GROUP BY m.category
ORDER BY fraud_rate_pct DESC;

-- ---------------------------------------------------------------------
-- A2. Fraud rate by hour of day
-- Finding: hours 22-23 run 2.5-2.6% and hours 0-3 about 1.3%, versus
--   roughly 0.09-0.13% for every other hour (15-20x spike overnight).
-- ---------------------------------------------------------------------
SELECT
    HOUR(t.trans_date_trans_time)                   AS hour_of_day,
    COUNT(*)                                        AS total_transactions,
    SUM(t.is_fraud)                                 AS fraud_count,
    ROUND(SUM(t.is_fraud) / COUNT(*) * 100, 3)      AS fraud_rate_pct
FROM transactions t
GROUP BY HOUR(t.trans_date_trans_time)
ORDER BY fraud_rate_pct DESC;

-- ---------------------------------------------------------------------
-- A3. Average transaction amount: fraud vs legitimate
-- Finding: $530.66 (fraud) vs $67.65 (legitimate), about 7.8x larger.
-- ---------------------------------------------------------------------
SELECT
    is_fraud,
    ROUND(AVG(amt), 2) AS avg_amount
FROM transactions
GROUP BY is_fraud;

-- ---------------------------------------------------------------------
-- A4. Fraud rate by state (minimum volume filter)
-- Small states give unstable rates (e.g. Delaware: 9 transactions,
-- 100% fraud), so states under 5,000 transactions are excluded.
-- Finding: modest spread across states, roughly 0.38% to 0.75%.
--   Geography is a weak signal here.
-- ---------------------------------------------------------------------
SELECT
    c.state,
    COUNT(*)                                        AS total_transactions,
    SUM(t.is_fraud)                                 AS fraud_count,
    ROUND(SUM(t.is_fraud) / COUNT(*) * 100, 3)      AS fraud_rate_pct
FROM transactions t
INNER JOIN customers c ON t.cc_num = c.cc_num
GROUP BY c.state
HAVING total_transactions >= 5000
ORDER BY fraud_rate_pct DESC;

-- ---------------------------------------------------------------------
-- A5. Repeat fraud victims
-- Finding: 976 of 999 cardholders (98%) had at least one fraud, averaging
--   about 10 incidents each. Fraud is spread across the customer base
--   rather than concentrated in a few cards.
-- ---------------------------------------------------------------------
SELECT cc_num, COUNT(*) AS fraud_count
FROM transactions
WHERE is_fraud = 1
GROUP BY cc_num
HAVING fraud_count > 1
ORDER BY fraud_count DESC;

SELECT COUNT(DISTINCT cc_num) AS customers_with_fraud   -- 976
FROM transactions
WHERE is_fraud = 1;

-- ---------------------------------------------------------------------
-- A6. Merchant-level fraud rate (grouped by merchant_id, min 1,000 txns)
-- Finding: the top merchants (1.87-2.18%) are all in shopping_net or
--   misc_net, only modestly above their category averages. Category is a
--   stronger signal than the individual merchant.
-- ---------------------------------------------------------------------
SELECT
    m.merchant_id,
    REPLACE(m.merchant_name, 'fraud_', '')          AS merchant,
    m.category,
    COUNT(*)                                        AS total_transactions,
    SUM(t.is_fraud)                                 AS fraud_count,
    ROUND(SUM(t.is_fraud) / COUNT(*) * 100, 3)      AS fraud_rate_pct
FROM transactions t
INNER JOIN merchants m ON t.merchant_id = m.merchant_id
GROUP BY m.merchant_id, m.merchant_name, m.category
HAVING total_transactions >= 1000
ORDER BY fraud_rate_pct DESC;

-- ---------------------------------------------------------------------
-- A7. Monthly fraud trend
-- Finding: no strong seasonality. Monthly fraud counts stay between
--   258 and 592, so the rate moves mostly inversely with volume (December
--   volume doubles and dilutes the rate). Yearly rate: 0.56% in 2019,
--   0.48% in 2020. Chart count and volume alongside the rate.
-- ---------------------------------------------------------------------
SELECT
    DATE_FORMAT(t.trans_date_trans_time, '%Y-%m')   AS month,
    COUNT(*)                                        AS total_transactions,
    SUM(t.is_fraud)                                 AS fraud_count,
    ROUND(SUM(t.is_fraud) / COUNT(*) * 100, 3)      AS fraud_rate_pct
FROM transactions t
GROUP BY DATE_FORMAT(t.trans_date_trans_time, '%Y-%m')
ORDER BY month;

-- ---------------------------------------------------------------------
-- A8. Fraud rate by cardholder age (age at time of transaction)
-- Finding: 35-44 lowest (0.394%), 55-64 highest (0.686%), 65+ 0.651%.
--   A moderate signal on a small customer base (999); treat as suggestive.
-- ---------------------------------------------------------------------
SELECT
    CASE
        WHEN TIMESTAMPDIFF(YEAR, c.dob, t.trans_date_trans_time) < 18 THEN '0-17'
        WHEN TIMESTAMPDIFF(YEAR, c.dob, t.trans_date_trans_time) < 25 THEN '18-24'
        WHEN TIMESTAMPDIFF(YEAR, c.dob, t.trans_date_trans_time) < 35 THEN '25-34'
        WHEN TIMESTAMPDIFF(YEAR, c.dob, t.trans_date_trans_time) < 45 THEN '35-44'
        WHEN TIMESTAMPDIFF(YEAR, c.dob, t.trans_date_trans_time) < 55 THEN '45-54'
        WHEN TIMESTAMPDIFF(YEAR, c.dob, t.trans_date_trans_time) < 65 THEN '55-64'
        ELSE '65+'
    END                                             AS age_group,
    COUNT(*)                                        AS total_transactions,
    SUM(t.is_fraud)                                 AS fraud_count,
    ROUND(SUM(t.is_fraud) / COUNT(*) * 100, 3)      AS fraud_rate_pct
FROM transactions t
INNER JOIN customers c ON t.cc_num = c.cc_num
GROUP BY age_group
ORDER BY age_group;

-- ---------------------------------------------------------------------
-- A9. Riskiest category x hour combinations
-- Finding: misc_net at hours 22-23 reaches about 22-23%; shopping_net at
--   the same hours 10-12%; grocery_pos peaks at hours 0-3 (about 2.7%),
--   which explains its elevated overall rate in A1. These top 10 cells
--   hold about 48% of all fraud from about 5% of transactions.
-- Sort by the rate (not the hour), and filter small cells with HAVING.
-- ---------------------------------------------------------------------
SELECT
    m.category,
    HOUR(t.trans_date_trans_time)                   AS hour_of_day,
    COUNT(*)                                        AS total_transactions,
    SUM(t.is_fraud)                                 AS fraud_count,
    ROUND(SUM(t.is_fraud) / COUNT(*) * 100, 3)      AS fraud_rate_pct
FROM transactions t
INNER JOIN merchants m ON t.merchant_id = m.merchant_id
GROUP BY m.category, HOUR(t.trans_date_trans_time)
HAVING total_transactions >= 500
ORDER BY fraud_rate_pct DESC
LIMIT 10;

-- ---------------------------------------------------------------------
-- A10. Fraud rate by transaction amount bucket
-- Finding: rate jumps at 250 (0.01-0.2% below; 7.8% for 250-499; about
--   21-22% at 500+). Transactions of 250+ are 2.9% of volume but hold
--   74.5% of all fraud. 2,069 frauds sit under 50, almost none between
--   50 and 249 (a two-cluster pattern, likely a simulation artifact).
-- ---------------------------------------------------------------------
SELECT
    CASE
        WHEN t.amt < 50   THEN '1. under 50'
        WHEN t.amt < 100  THEN '2. 50-99'
        WHEN t.amt < 250  THEN '3. 100-249'
        WHEN t.amt < 500  THEN '4. 250-499'
        WHEN t.amt < 1000 THEN '5. 500-999'
        ELSE '6. 1000+'
    END                                             AS amount_bucket,
    COUNT(*)                                        AS total_transactions,
    SUM(t.is_fraud)                                 AS fraud_count,
    ROUND(SUM(t.is_fraud) / COUNT(*) * 100, 3)      AS fraud_rate_pct
FROM transactions t
GROUP BY amount_bucket
ORDER BY amount_bucket;

-- ---------------------------------------------------------------------
-- A11. Rule evaluation: time/category flag x amount flag (CTE)
--   time_flag   = online categories at hours 22-23, or grocery_pos at 0-3
--   amount_flag = amt >= 250
-- Result:
--   time  amt   transactions   frauds   fraud rate
--     0    0     1,726,940      2,454     0.142%
--     0    1        48,708      3,224     6.619%
--     1    0        71,531          5     0.007%
--     1    1         5,215      3,968    76.088%
-- Reading it:
--   * The time window adds almost nothing on its own (5 frauds in 71,531
--     flagged): the night-time pattern is really a large-amount pattern.
--   * Time AND amount: precision 76.1%, recall 41.1% (5,215 flagged,
--     0.28% of volume).
--   * Amount only: precision 13.3%, recall 74.5%.
--   * Time OR amount: precision 5.7%, recall 74.6% (worst trade-off).
--   * About 25% of fraud (2,454) is caught by neither rule, mostly small
--     transactions under 50.
-- Suggested tiers: High = both flags (76% fraud), Medium = amount only
--   (6.6%), Low = neither (0.14%).
-- Thresholds were chosen on the same data they are measured on, so
--   precision and recall are optimistic.
-- ---------------------------------------------------------------------
WITH flagged AS (
    SELECT
        t.is_fraud,
        CASE
            WHEN (m.category IN ('shopping_net', 'misc_net')
                  AND HOUR(t.trans_date_trans_time) IN (22, 23))
              OR (m.category = 'grocery_pos'
                  AND HOUR(t.trans_date_trans_time) BETWEEN 0 AND 3) THEN 1
            ELSE 0
        END AS time_flag,
        CASE WHEN t.amt >= 250 THEN 1 ELSE 0 END AS amount_flag
    FROM transactions t
    INNER JOIN merchants m ON t.merchant_id = m.merchant_id
)
SELECT
    time_flag,
    amount_flag,
    COUNT(*)                                        AS total_transactions,
    SUM(is_fraud)                                   AS fraud_count,
    ROUND(SUM(is_fraud) / COUNT(*) * 100, 3)        AS fraud_rate_pct
FROM flagged
GROUP BY time_flag, amount_flag
ORDER BY time_flag, amount_flag;


/* =====================================================================
   7. APPENDIX: WINDOW-FUNCTION EXAMPLES
   Technique reference; these restate A1 and A7 with window functions.
   ===================================================================== */

-- Rank categories by fraud rate. Rank on the raw ratio and round only
-- for display: ranking on the rounded value creates false ties
-- (home 0.15103% vs health_fitness 0.15096% both round to 0.151).
SELECT
    m.category,
    COUNT(*)                                        AS total_transactions,
    ROUND(SUM(t.is_fraud) / COUNT(*) * 100, 3)      AS fraud_rate_pct,
    RANK() OVER (ORDER BY SUM(t.is_fraud) / COUNT(*) DESC) AS risk_rank
FROM transactions t
INNER JOIN merchants m ON t.merchant_id = m.merchant_id
GROUP BY m.category
ORDER BY risk_rank;

-- Cumulative fraud by month; the last row must equal 9,651.
SELECT
    DATE_FORMAT(t.trans_date_trans_time, '%Y-%m')   AS month,
    SUM(t.is_fraud)                                 AS monthly_fraud,
    SUM(SUM(t.is_fraud)) OVER (
        ORDER BY DATE_FORMAT(t.trans_date_trans_time, '%Y-%m')
    )                                               AS cumulative_fraud
FROM transactions t
GROUP BY DATE_FORMAT(t.trans_date_trans_time, '%Y-%m')
ORDER BY month;


/* =====================================================================
   8. LIMITATIONS
   - Synthetic dataset: fraud is injected into specific windows (hour and
     amount clusters), so concentrations are stronger than real-world
     card fraud. Cardholders as young as 13 also indicate simulation.
   - Only 999 customers and 700 merchants: customer-level, age-level and
     merchant-level differences rest on small groups.
   - Rule thresholds were derived from the same data used to evaluate
     them, so precision/recall are optimistic; a true holdout is needed.
   - merchants stores one representative coordinate per merchant, so
     transaction-level merchant distance needs staging_transactions.
   ===================================================================== */
