-- ch06_basic_10.sql — 実業務10クエリ（第6章 §6.8）
-- codes/sql-code/queries/ch06_basic_10.sql@v1.2.2
-- 前提: init-small 以上を投入済み（既定DB sakura_market）。口径は README「業務ルール」参照
--       （売上=明細の合計・cancelled/returned除外・ordered_at基準・JST）。
SET search_path TO sakura, public;

-- Q1 月別売上推移（直近12ヶ月、前月比つき）
-- 期間は「締まった月」だけにする（JSTの今月1日の12か月前 〜 今月1日の前）。
-- now() - interval '12 months' で切ると、最初の月と今月が途中までの数字になり、前月比が大きく崩れる
WITH bounds AS (
    SELECT (date_trunc('month', now() AT TIME ZONE 'Asia/Tokyo') AT TIME ZONE 'Asia/Tokyo') AS this_month
),
monthly AS (
    SELECT date_trunc('month', o.ordered_at AT TIME ZONE 'Asia/Tokyo')::date AS m,
           SUM(oi.quantity * oi.price)::bigint AS sales
    FROM orders o JOIN order_items oi ON oi.order_id = o.id
    CROSS JOIN bounds b
    WHERE o.status NOT IN ('cancelled', 'returned')
      AND o.ordered_at >= b.this_month - interval '12 months'
      AND o.ordered_at < b.this_month
    GROUP BY 1
)
SELECT m, sales,
       LAG(sales) OVER (ORDER BY m) AS prev_sales,
       round(100.0 * (sales - LAG(sales) OVER (ORDER BY m))
             / NULLIF(LAG(sales) OVER (ORDER BY m), 0), 2) AS mom_pct
FROM monthly ORDER BY m;

-- Q2 カテゴリ別売上構成比
WITH cat_sales AS (
    SELECT c.name AS category_name, SUM(oi.quantity * oi.price)::bigint AS sales
    FROM order_items oi
    JOIN orders o ON oi.order_id = o.id
    JOIN products p ON oi.product_id = p.id
    JOIN categories c ON p.category_id = c.id
    WHERE o.status NOT IN ('cancelled', 'returned')
    GROUP BY c.name
)
SELECT category_name, sales,
       round(100.0 * sales / NULLIF(SUM(sales) OVER (), 0), 2) AS share_pct
FROM cat_sales ORDER BY sales DESC;

-- Q3 リピート率（過去365日、2回以上購入）
WITH user_days AS (
    SELECT DISTINCT user_id, ordered_at::date AS d FROM orders
    WHERE ordered_at >= now() - interval '365 days'
      AND status NOT IN ('cancelled', 'returned')
),
user_counts AS (
    SELECT user_id, count(*) AS order_count FROM user_days GROUP BY user_id
)
SELECT count(*) AS users,
       count(*) FILTER (WHERE order_count >= 2) AS repeat_users,
       round(100.0 * count(*) FILTER (WHERE order_count >= 2) / NULLIF(count(*), 0), 2) AS repeat_rate_pct
FROM user_counts;

-- Q4 顧客生涯価値LTVの簡易計算（ランク別）
WITH user_sales AS (
    SELECT u.id, u.rank, COALESCE(SUM(oi.quantity * oi.price), 0)::bigint AS ltv
    FROM users u
    LEFT JOIN orders o ON o.user_id = u.id AND o.status NOT IN ('cancelled', 'returned')
    LEFT JOIN order_items oi ON oi.order_id = o.id
    GROUP BY u.id, u.rank
)
SELECT rank,
       count(*) AS users,
       round(AVG(ltv), 2) AS avg_ltv,
       MAX(ltv) AS max_ltv
FROM user_sales GROUP BY rank ORDER BY avg_ltv DESC;

-- Q5 カゴ落ち分析（直近30日にカート追加したが購入していない user×product）
WITH cart AS (
    SELECT DISTINCT user_id, product_id FROM behavior_logs
    WHERE action = 'add_to_cart'
      AND created_at >= now() - interval '30 days'
      AND user_id IS NOT NULL AND product_id IS NOT NULL
),
purchased AS (
    SELECT DISTINCT o.user_id, oi.product_id
    FROM orders o JOIN order_items oi ON oi.order_id = o.id
    WHERE o.status NOT IN ('cancelled', 'returned')
      AND o.ordered_at >= now() - interval '30 days'
)
SELECT c.user_id, c.product_id
FROM cart c LEFT JOIN purchased pu
  ON pu.user_id = c.user_id AND pu.product_id = c.product_id
WHERE pu.user_id IS NULL
LIMIT 100;

-- Q6 商品別返品率（注文10件以上の商品）
-- 分母は「取消以外の注文」。返品された注文も分母に入れる（返品を除くと返品率が過大になる）
WITH order_counts AS (
    SELECT oi.product_id, count(DISTINCT oi.order_id) AS order_count
    FROM order_items oi JOIN orders o ON oi.order_id = o.id
    WHERE o.status <> 'cancelled'
    GROUP BY oi.product_id
),
return_counts AS (
    SELECT oi.product_id, count(DISTINCT r.id) AS return_count
    FROM returns r
    JOIN orders o ON r.order_id = o.id
    JOIN order_items oi ON oi.order_id = o.id
    GROUP BY oi.product_id
)
SELECT p.sku, p.name_ja, oc.order_count,
       COALESCE(rc.return_count, 0) AS return_count,
       round(100.0 * COALESCE(rc.return_count, 0) / NULLIF(oc.order_count, 0), 2) AS return_rate_pct
FROM order_counts oc
JOIN products p ON p.id = oc.product_id
LEFT JOIN return_counts rc ON rc.product_id = oc.product_id
WHERE oc.order_count >= 10
ORDER BY return_rate_pct DESC, p.sku
LIMIT 20;

-- Q7 会員ランク別平均注文額（orders.amount = 請求額: 小計 - 値引き + 送料）
SELECT u.rank,
       count(*) AS orders,
       round(AVG(o.amount), 2) AS avg_amount,
       MIN(o.amount) AS min_amount,
       MAX(o.amount) AS max_amount
FROM orders o JOIN users u ON o.user_id = u.id
WHERE o.status NOT IN ('cancelled', 'returned')
GROUP BY u.rank ORDER BY avg_amount DESC;

-- Q8 時間帯別注文数（JST、直近90日）
SELECT EXTRACT(HOUR FROM ordered_at AT TIME ZONE 'Asia/Tokyo')::int AS hour_jst,
       count(*) AS orders
FROM orders
WHERE ordered_at >= now() - interval '90 days'
GROUP BY 1 ORDER BY 1;

-- Q9 クーポン利用率（上限のあるクーポンだけ率が出る。上限なし＝NULL は後ろに並べる）
-- used は「取り消されていない注文での使用数」で、coupons.used_count と一致する（checks で照合）
SELECT c.code, c.max_uses,
       count(o.id) AS used,
       sum(o.discount_amount) AS total_discount,
       round(100.0 * count(o.id) / NULLIF(c.max_uses, 0), 2) AS usage_pct
FROM coupons c
LEFT JOIN orders o ON o.coupon_id = c.id AND o.status <> 'cancelled'
GROUP BY c.code, c.max_uses ORDER BY usage_pct DESC NULLS LAST, c.code;

-- Q10 在庫切れ間近（在庫10以下、有効商品）
SELECT p.sku, p.name_ja, c.name AS category_name, i.stock
FROM inventory i
JOIN products p ON p.id = i.product_id
LEFT JOIN categories c ON p.category_id = c.id
WHERE i.stock <= 10 AND p.deleted_at IS NULL
ORDER BY i.stock, p.sku
LIMIT 20;
