-- ch07_ai_design_3cases.sql — 同一要件の3案比較（第7章 §7.4）
-- codes/sql-code/queries/ch07_ai_design_3cases.sql@v1.2.2
-- 要件: 過去30日のカテゴリ別売上を、前月比（直前30日比）とともに表示。
-- 口径: 売上=SUM(qty*price)、cancelled/returned除外、ordered_at基準。
-- 前提: 既定DB sakura_market（small＋medium）。
SET search_path TO sakura, public;

-- 案A: サブクエリ多用（素朴・読みにくい）。カテゴリ数×2回、注文と明細を読み直す
SELECT category_name, sales_30d, sales_prev_30d,
       round(100.0 * (sales_30d - sales_prev_30d) / NULLIF(sales_prev_30d, 0), 2) AS growth_pct
FROM (
    SELECT c.name AS category_name,
        (SELECT COALESCE(SUM(oi.quantity * oi.price), 0)
         FROM orders o JOIN order_items oi ON oi.order_id = o.id
         JOIN products p ON oi.product_id = p.id
         WHERE p.category_id = c.id
           AND o.status NOT IN ('cancelled', 'returned')
           AND o.ordered_at >= now() - interval '30 days') AS sales_30d,
        (SELECT COALESCE(SUM(oi.quantity * oi.price), 0)
         FROM orders o JOIN order_items oi ON oi.order_id = o.id
         JOIN products p ON oi.product_id = p.id
         WHERE p.category_id = c.id
           AND o.status NOT IN ('cancelled', 'returned')
           AND o.ordered_at >= now() - interval '60 days'
           AND o.ordered_at < now() - interval '30 days') AS sales_prev_30d
    FROM categories c
) AS a
ORDER BY sales_30d DESC, category_name;

-- 案B: CTEで整理（可読・保守◎）。注文を1回だけ読み、FILTER で2期間に振り分ける
WITH target_orders AS (
    SELECT o.id, o.ordered_at FROM orders o
    WHERE o.status NOT IN ('cancelled', 'returned')
      AND o.ordered_at >= now() - interval '60 days'
),
sales AS (
    SELECT p.category_id,
           SUM(oi.quantity * oi.price)
               FILTER (WHERE o.ordered_at >= now() - interval '30 days') AS sales_30d,
           SUM(oi.quantity * oi.price)
               FILTER (WHERE o.ordered_at < now() - interval '30 days') AS sales_prev_30d
    FROM target_orders o
    JOIN order_items oi ON oi.order_id = o.id
    JOIN products p ON oi.product_id = p.id
    GROUP BY p.category_id
)
SELECT c.name AS category_name,
       COALESCE(s.sales_30d, 0) AS sales_30d,
       COALESCE(s.sales_prev_30d, 0) AS sales_prev_30d,
       round(100.0 * (COALESCE(s.sales_30d, 0) - COALESCE(s.sales_prev_30d, 0))
             / NULLIF(s.sales_prev_30d, 0), 2) AS growth_pct
FROM categories c LEFT JOIN sales s ON s.category_id = c.id
ORDER BY sales_30d DESC, category_name;

-- 案C【誤り例・教材として残す】: 日次に集計してから2期間に足し上げる（2段集計）
-- AIが「日次集計しておけば速い」と出しがちな形。性能の考え方は正しいが、期間の境界がずれる:
--   (1) o.ordered_at::date はセッションの TimeZone 次第で日付が変わる（隠れた依存）
--   (2) (now() - interval '30 days')::date で境界が「その日の0時」に丸められ、
--       直近30日に最大1日分多く入り、直前30日からその分が抜ける → 案A・Bと数字が一致しない
WITH daily AS (
    SELECT p.category_id, o.ordered_at::date AS d,
           SUM(oi.quantity * oi.price) AS sales
    FROM orders o
    JOIN order_items oi ON oi.order_id = o.id
    JOIN products p ON oi.product_id = p.id
    WHERE o.status NOT IN ('cancelled', 'returned')
      AND o.ordered_at >= now() - interval '60 days'
    GROUP BY p.category_id, o.ordered_at::date
),
agg AS (
    SELECT category_id,
           SUM(sales) FILTER (WHERE d >= (now() - interval '30 days')::date) AS sales_30d,
           SUM(sales) FILTER (WHERE d < (now() - interval '30 days')::date) AS sales_prev_30d
    FROM daily GROUP BY category_id
)
SELECT c.name AS category_name,
       COALESCE(a.sales_30d, 0) AS sales_30d,
       COALESCE(a.sales_prev_30d, 0) AS sales_prev_30d,
       round(100.0 * (COALESCE(a.sales_30d, 0) - COALESCE(a.sales_prev_30d, 0))
             / NULLIF(a.sales_prev_30d, 0), 2) AS growth_pct
FROM categories c LEFT JOIN agg a ON a.category_id = c.id
ORDER BY sales_30d DESC, category_name;

-- 案C'（修正版）: 2段集計のまま、期間を「JSTの日付」で定義し直す
--   直近30日 = 昨日までの30日間 [今日-30日, 今日)、直前30日 = [今日-60日, 今日-30日)（JST、半開区間）
--   日次の表（第14章 daily_category_sales）にそのまま載せ替えられる形。
--   注意: 「今この瞬間から30日前」（案A・B）とは口径が違う。どちらにするかは要件で決め、明記する
WITH bounds AS (
    SELECT (now() AT TIME ZONE 'Asia/Tokyo')::date AS today
),
daily AS (
    SELECT p.category_id, (o.ordered_at AT TIME ZONE 'Asia/Tokyo')::date AS d,
           SUM(oi.quantity * oi.price) AS sales
    FROM orders o
    JOIN order_items oi ON oi.order_id = o.id
    JOIN products p ON oi.product_id = p.id
    CROSS JOIN bounds b
    -- 時刻の範囲で絞る（索引 idx_orders_ordered_at が使える。列を関数で包まない）
    -- 日付は ::timestamp にしてから AT TIME ZONE を付ける（date のままだとセッションの TimeZone で解釈される）
    WHERE o.status NOT IN ('cancelled', 'returned')
      AND o.ordered_at >= (b.today - 60)::timestamp AT TIME ZONE 'Asia/Tokyo'
      AND o.ordered_at < b.today::timestamp AT TIME ZONE 'Asia/Tokyo'
    GROUP BY p.category_id, (o.ordered_at AT TIME ZONE 'Asia/Tokyo')::date
),
agg AS (
    SELECT category_id,
           SUM(sales) FILTER (WHERE d >= b.today - 30) AS sales_30d,
           SUM(sales) FILTER (WHERE d < b.today - 30) AS sales_prev_30d
    FROM daily CROSS JOIN bounds b
    GROUP BY category_id
)
SELECT c.name AS category_name,
       COALESCE(a.sales_30d, 0) AS sales_30d,
       COALESCE(a.sales_prev_30d, 0) AS sales_prev_30d,
       round(100.0 * (COALESCE(a.sales_30d, 0) - COALESCE(a.sales_prev_30d, 0))
             / NULLIF(a.sales_prev_30d, 0), 2) AS growth_pct
FROM categories c LEFT JOIN agg a ON a.category_id = c.id
ORDER BY sales_30d DESC, category_name;

-- 検算: 案B と 案C の合計を比べる（差が0でなければ、案Cの境界ずれが数字に出ている）
SELECT
    (SELECT SUM(oi.quantity * oi.price) FROM orders o JOIN order_items oi ON oi.order_id = o.id
     WHERE o.status NOT IN ('cancelled', 'returned')
       AND o.ordered_at >= now() - interval '30 days') AS b_sales_30d,
    (SELECT SUM(oi.quantity * oi.price) FROM orders o JOIN order_items oi ON oi.order_id = o.id
     WHERE o.status NOT IN ('cancelled', 'returned')
       AND o.ordered_at >= now() - interval '60 days'
       AND o.ordered_at::date >= (now() - interval '30 days')::date) AS c_sales_30d;

-- 比較観点（企画 §7.4）: 可読性 A△/B○/C○、性能 A△/B○/C◎、保守性 A△/B○/C○、PG依存 A低/B低/C低。
-- 選定: 本書では案Bを標準とし、大規模では案C'（日次集計）＋集計表・マテビュー（第12・14章）へ進む。
