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
