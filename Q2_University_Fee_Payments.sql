-- =====================================================================
-- ICT371 Advanced Database | Question 2: University Fee Payments
-- Target DBMS: PostgreSQL 14+ (PL/pgSQL). Scheduling uses the pg_cron extension.
-- Run with:  psql -d your_database -f Q2_University_Fee_Payments.sql
-- =====================================================================

-- ---------------------------------------------------------------------
-- (a) Database and seed data
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS daily_collections, payment_audit, payments, students CASCADE;

CREATE TABLE students (
    student_id      SERIAL        PRIMARY KEY,
    student_number  VARCHAR(20)   NOT NULL UNIQUE,
    full_name       VARCHAR(100)  NOT NULL,
    fee_due         NUMERIC(12,2) NOT NULL CHECK (fee_due >= 0)
);

CREATE TABLE payments (
    payment_id  SERIAL        PRIMARY KEY,
    student_id  INTEGER       NOT NULL REFERENCES students (student_id),
    amount      NUMERIC(12,2) NOT NULL CHECK (amount > 0),
    paid_on     DATE          NOT NULL
);

CREATE TABLE payment_audit (
    audit_id    SERIAL        PRIMARY KEY,
    payment_id  INTEGER       NOT NULL REFERENCES payments (payment_id),
    student_id  INTEGER       NOT NULL REFERENCES students (student_id),
    amount      NUMERIC(12,2) NOT NULL,
    logged_at   TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE daily_collections (
    collection_date  DATE          PRIMARY KEY,
    payment_count    INTEGER       NOT NULL DEFAULT 0,
    total_amount     NUMERIC(14,2) NOT NULL DEFAULT 0
);

-- Three students with different fee balances (payments are loaded at the end,
-- through the procedure, so that the audit trigger records them)
INSERT INTO students (student_number, full_name, fee_due) VALUES
    ('S2026001', 'Alice Banda',   5000.00),
    ('S2026002', 'Brian Phiri',   3000.00),
    ('S2026003', 'Chipo Mwansa',  4000.00);   -- will have NO payments

-- ---------------------------------------------------------------------
-- (b) Function fn_fee_balance
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_fee_balance(p_student_id INTEGER)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_fee  NUMERIC(12,2);
    v_paid NUMERIC(14,2);
BEGIN
    SELECT fee_due INTO v_fee
    FROM students
    WHERE student_id = p_student_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student_id: %', p_student_id;
    END IF;

    -- COALESCE gives 0 when the student has no payments => full fee returned
    SELECT COALESCE(SUM(amount), 0) INTO v_paid
    FROM payments
    WHERE student_id = p_student_id;

    RETURN v_fee - v_paid;
END;
$$;

-- ---------------------------------------------------------------------
-- (c) Procedure pr_receive_payment (does NOT insert the audit row itself)
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_receive_payment(p_student_id INTEGER, p_amount NUMERIC, p_paid_on DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_balance NUMERIC;
BEGIN
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Invalid payment amount: % (must be greater than zero)', p_amount;
    END IF;
    IF p_paid_on IS NULL THEN
        RAISE EXCEPTION 'Payment date must not be NULL';
    END IF;

    -- Lock the student row so concurrent payments cannot overpay together
    PERFORM 1 FROM students WHERE student_id = p_student_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student_id: %', p_student_id;
    END IF;

    v_balance := fn_fee_balance(p_student_id);

    IF p_amount > v_balance THEN
        RAISE EXCEPTION 'Payment % exceeds outstanding balance % (credit balances are not allowed)',
                        p_amount, v_balance;
    END IF;

    -- fee_due is never changed; the balance is always derived from payments
    INSERT INTO payments (student_id, amount, paid_on)
    VALUES (p_student_id, p_amount, p_paid_on);
END;
$$;

-- ---------------------------------------------------------------------
-- (d) Trigger: audit every payment automatically (AFTER INSERT, row level)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_payment_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO payment_audit (payment_id, student_id, amount, logged_at)
    VALUES (NEW.payment_id, NEW.student_id, NEW.amount, CURRENT_TIMESTAMP);
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_payment_audit ON payments;
CREATE TRIGGER trg_payment_audit
AFTER INSERT ON payments
FOR EACH ROW
EXECUTE FUNCTION trg_fn_payment_audit();

-- ---------------------------------------------------------------------
-- (e) View: v_fee_balances (only students who still owe fees)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_fee_balances AS
SELECT s.student_number,
       s.full_name,
       s.fee_due - COALESCE(SUM(p.amount), 0) AS outstanding_balance
FROM students s
LEFT JOIN payments p ON p.student_id = s.student_id
GROUP BY s.student_id, s.student_number, s.full_name, s.fee_due
HAVING s.fee_due - COALESCE(SUM(p.amount), 0) > 0;

-- ---------------------------------------------------------------------
-- (f) Composite index: payments by student_id and a paid_on range
--     student_id (equality) first, paid_on (range) second.
-- ---------------------------------------------------------------------
CREATE INDEX idx_payments_student_paid_on ON payments (student_id, paid_on);

-- ---------------------------------------------------------------------
-- (g) Scheduled job: pr_refresh_collections (replaces an existing row on rerun)
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_collections(p_day DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'Day must not be NULL';
    END IF;

    INSERT INTO daily_collections (collection_date, payment_count, total_amount)
    SELECT p_day, COUNT(*), COALESCE(SUM(amount), 0)
    FROM payments
    WHERE paid_on = p_day
    ON CONFLICT (collection_date)
    DO UPDATE SET payment_count = EXCLUDED.payment_count,
                  total_amount  = EXCLUDED.total_amount;
END;
$$;

CREATE EXTENSION IF NOT EXISTS pg_cron;

-- Every day at 01:00, for the previous day
SELECT cron.schedule(
    'fees_refresh_collections',
    '0 1 * * *',
    $$CALL pr_refresh_collections(CURRENT_DATE - 1)$$
);

-- =====================================================================
-- DEMONSTRATION / TESTING
-- =====================================================================

-- (a) Six valid payments through the procedure (Chipo, student 3, pays nothing)
CALL pr_receive_payment(1, 1000.00, CURRENT_DATE - 3);
CALL pr_receive_payment(1, 1500.00, CURRENT_DATE - 2);
CALL pr_receive_payment(1,  500.00, CURRENT_DATE - 1);
CALL pr_receive_payment(2, 1000.00, CURRENT_DATE - 1);
CALL pr_receive_payment(2,  500.00, CURRENT_DATE - 1);
CALL pr_receive_payment(2, 1500.00, CURRENT_DATE);        -- Brian is now fully settled

SELECT * FROM students ORDER BY student_id;               -- fee_due unchanged
SELECT * FROM payments ORDER BY payment_id;
SELECT * FROM payment_audit ORDER BY audit_id;            -- written by the trigger

-- (b) Balances
SELECT fn_fee_balance(1) AS alice_balance,                -- 2000.00
       fn_fee_balance(2) AS brian_balance,                -- 0.00
       fn_fee_balance(3) AS chipo_full_fee;               -- 4000.00 (no payments)
-- SELECT fn_fee_balance(99);                             -- ERROR: Unknown student_id

-- (c) Rejected payments (uncomment one at a time)
-- CALL pr_receive_payment(1, NULL, CURRENT_DATE);        -- ERROR: invalid amount
-- CALL pr_receive_payment(1, 0, CURRENT_DATE);           -- ERROR: invalid amount
-- CALL pr_receive_payment(1, -50, CURRENT_DATE);         -- ERROR: invalid amount
-- CALL pr_receive_payment(1, 2500, CURRENT_DATE);        -- ERROR: exceeds balance (2000)
-- CALL pr_receive_payment(99, 100, CURRENT_DATE);        -- ERROR: Unknown student_id

-- (e) View: Brian (settled) is excluded
SELECT * FROM v_fee_balances ORDER BY student_number;

-- (f) EXPLAIN (seqscan disabled only because the demo table is tiny)
SET enable_seqscan = off;
EXPLAIN
SELECT *
FROM payments
WHERE student_id = 1
  AND paid_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;
RESET enable_seqscan;

-- (g) Run twice: the summary row is replaced, not added to
CALL pr_refresh_collections(CURRENT_DATE - 1);
CALL pr_refresh_collections(CURRENT_DATE - 1);
SELECT * FROM daily_collections ORDER BY collection_date;

SELECT jobid, jobname, schedule, command, active FROM cron.job;
