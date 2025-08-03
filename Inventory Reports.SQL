-- Expiring PO Report

--Only POs for the current financial year needs to be displayed

WITH fy_calc AS (
    SELECT
        CURRENT_DATE AS sel_date,
        MAKE_DATE(
            CASE
                WHEN EXTRACT(MONTH FROM CURRENT_DATE)::int < 4
                     THEN EXTRACT(YEAR FROM CURRENT_DATE)::int - 1
                ELSE EXTRACT(YEAR FROM CURRENT_DATE)::int
            END,
            4, 1
        ) AS fy_start_date
)

SELECT
    po.po_id,
	po.po_number,
    po.po_type,
    po_items.product_part_number,
    po.po_start_date   AS Start_Date,
    po.po_end_date     AS End_Date,
    po_items.po_quantity,
    po_items.po_pending_quantity
FROM po
LEFT JOIN po_items       ON po_items.po_id = po.po_id
LEFT JOIN users_category ON users_category.id = po.category_id
JOIN fy_calc             ON TRUE          -- just to bring the FY dates in
WHERE
      po.po_type = 'CPO'
  AND {{selected_date}}                  -- Field Filter → map to po.po_end_date
  AND {{category_id}}                   -- Field Filter → map to users_category.id
  AND po.po_start_date >= fy_calc.fy_start_date
ORDER BY po.po_end_date;

-- Pending Payments Report

SELECT
    ROW_NUMBER() OVER (ORDER BY receipt.receipt_id)               AS row_num,
    po.po_number,
    receipt.invoice_number,
    TO_CHAR(
        (receipt.invoice_date AT TIME ZONE 'UTC' AT TIME ZONE 'Asia/Kolkata'),
        'dd-mm-yyyy'
    )                                                             AS invoice_date,
    receipt.invoice_amount,
    vendor.name,
    receipt_accounts.total_paid,
    receipt_accounts.pending_amount,
    CASE
        WHEN users_category.type = 'ZONE' THEN 'CPO'
        ELSE po.po_type
    END                                                           AS po_type
FROM receipt_items
LEFT JOIN po_items         ON po_items.po_items_id   = receipt_items.po_items_id
LEFT JOIN receipt          ON receipt.receipt_id     = receipt_items.receipt_id
LEFT JOIN po               ON po.po_id               = ANY(receipt.po_id)
LEFT JOIN vendor           ON vendor.vendor_id       = po.vendor_id
LEFT JOIN receipt_accounts ON receipt_accounts.receipt_id = receipt.receipt_id
LEFT JOIN users_category   ON users_category.id      = po.category_id
WHERE {{name}}
AND po.po_type ='CPO'-- Field Filter → map to users_category.id
ORDER BY receipt.receipt_id;

--Re-Order Level Report

/* ---------- 1. Start‑of‑current financial year (APR‑01) ---------- */
WITH financial_year_start AS (
    SELECT
        CASE
            WHEN EXTRACT(MONTH FROM CURRENT_DATE) >= 4
                 THEN MAKE_DATE(EXTRACT(YEAR FROM CURRENT_DATE)::int, 4, 1)
            ELSE MAKE_DATE((EXTRACT(YEAR FROM CURRENT_DATE) - 1)::int, 4, 1)
        END AS fy_start_date
),

/* ---------- 2. Base products with filter ---------- */
base_products AS (
    SELECT
        part_number,
		name,
		code,
		uom,
        reorder_level_quantity
    FROM product
    WHERE {{part_number}}
),

/* ---------- 3. In‑store stock per part ---------- */
store_aggregates AS (
    SELECT
        st.part_number,
        SUM(st.quantity) AS total_stock
    FROM store st
    JOIN base_products bp ON st.part_number = bp.part_number
    GROUP BY st.part_number
),

/* ---------- 4. Pending CPO quantity per part ---------- */
po_aggregates AS (
    SELECT
        pi.product_part_number,
        SUM(pi.po_pending_quantity) AS total_pending
    FROM po_items pi
    JOIN po ON po.po_id = pi.po_id
    JOIN base_products bp ON pi.product_part_number = bp.part_number
    WHERE po.po_type = 'CPO'
    GROUP BY pi.product_part_number
),

/* ---------- 5. Consumption since FY start ---------- */
consumption_data AS (
    SELECT
        bp.part_number,
        mii.created_at,
        mii.issued_quantity,
        bp.reorder_level_quantity,
		bp.name,
		bp.uom,
		bp.code
    FROM base_products bp
    LEFT JOIN material_issue_items mii
           ON mii.product_part_number = bp.part_number
          AND mii.created_at >= (SELECT fy_start_date FROM financial_year_start)
)

/* ---------- 6. Final output (only if consumption > 0) ---------- */
SELECT
    cd.part_number,
    COALESCE(ABS(SUM(cd.issued_quantity)),0) AS total_consumption,
    cd.reorder_level_quantity,
	cd.name,
	cd.uom,
	cd.code,
    COALESCE(sa.total_stock,0) AS current_stock,
    COALESCE(pa.total_pending,0) AS total_pending_po,
    CURRENT_DATE - (SELECT fy_start_date FROM financial_year_start) + 1 AS days_elapsed,
    ROUND(
        COALESCE(ABS(SUM(cd.issued_quantity)),0)::numeric
        / NULLIF(
            (CURRENT_DATE - (SELECT fy_start_date FROM financial_year_start) + 1),
            0
        ),
        2
    ) AS daily_consumption_rate
FROM consumption_data cd
LEFT JOIN store_aggregates sa ON sa.part_number = cd.part_number
LEFT JOIN po_aggregates pa ON pa.product_part_number = cd.part_number
GROUP BY
    cd.part_number,
    cd.reorder_level_quantity,
	cd.name,
	cd.uom,
	cd.code,
    sa.total_stock,
    pa.total_pending
HAVING SUM(cd.issued_quantity) <> 0
ORDER BY total_consumption ASC;
