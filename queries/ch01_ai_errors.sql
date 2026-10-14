-- ch01_ai_errors.sql — AIが犯す4つの典型エラー＋3ケース（第1章 §1.2–1.3）
-- codes/sql-code/queries/ch01_ai_errors.sql@v1.2.2
-- 前提: init-small 投入済み。SELECTのみ（書き換え系はBEGINで包む）。
SET search_path TO sakura, public;

-- ===== エラー1: 列の混同（「顧客名」を求められてログインIDに近い別列を返す） =====
-- 誤答例: emailを「顧客名」として返す（一見動くが業務的に誤り）
SELECT email AS customer_name FROM users WHERE rank = 'gold' LIMIT 5;
-- 正: 表示名を返す
SELECT display_name AS customer_name FROM users WHERE rank = 'gold' LIMIT 5;

-- 金額の列の混同（v1.2.0〜）: 「売上」を orders.amount（請求額）で足してしまう。
-- 請求額は 小計 - クーポン値引き + 送料 なので、本書の売上（明細の合計＝商品売上）とは一致しない
SELECT SUM(o.amount) AS sum_amount,                 -- 誤: 請求額の合計（送料を含み、値引き後）
       SUM(o.subtotal) AS sum_subtotal,             -- 正: 商品売上（明細の合計と一致）
       SUM(o.discount_amount) AS sum_discount,
       SUM(o.shipping_fee) AS sum_shipping
FROM orders o
WHERE o.status NOT IN ('cancelled', 'returned');

-- ===== エラー2: JOINの誤り（INNER/LEFT取違えで行が消える・膨張する） =====
-- 誤答例: 未注文者を含めたいのにINNER JOINで行が消える
SELECT count(*) AS inner_join_users
FROM users u INNER JOIN orders o ON o.user_id = u.id;
-- 正: LEFT JOIN＋集計
SELECT count(DISTINCT u.id) AS all_users,
       count(DISTINCT o.user_id) AS ordered_users
FROM users u LEFT JOIN orders o ON o.user_id = u.id;

-- fan-out例: カテゴリを経由した不要JOINで注文件数が水増しされる
SELECT count(*) AS inflated
FROM orders o
INNER JOIN order_items oi ON oi.order_id = o.id
INNER JOIN products p ON oi.product_id = p.id
INNER JOIN categories c ON p.category_id = c.id;
-- 正: 注文件数ならordersだけ数える
SELECT count(*) AS orders_only FROM orders;

-- ===== エラー3: NULLの罠 =====
-- COUNT(*) と COUNT(col) の差: クーポンを使わない注文は coupon_id が NULL。
-- 小規模データ（50件）でも一部の注文だけがクーポンを使うので、2つの数が食い違う
SELECT count(*) AS cnt_star, count(coupon_id) AS cnt_coupon
FROM orders;
-- NULL比較の罠（= NULL はUNKNOWNで0行）
SELECT count(*) AS eq_null_rows FROM products WHERE name_en = NULL;
-- 正
SELECT count(*) AS is_null_rows FROM products WHERE name_en IS NULL;

-- ===== エラー4: 危険な全表操作（WHEREなしUPDATE） =====
BEGIN;
UPDATE products SET price = price * 1.1;  -- 全商品が対象！
SELECT count(*) AS affected_all FROM products;  -- 影響行を確認
ROLLBACK;  -- 必ず巻き戻す
-- 正: 対象を絞ってから、件数を確認してCOMMIT
BEGIN;
SELECT count(*) AS target FROM products WHERE category_id IN (
    SELECT id FROM categories WHERE name = 'books');
-- UPDATE products SET price = price * 1.1 WHERE ...;
ROLLBACK;

-- ===== ケース1: 売上集計（返品・キャンセルの扱いで数字が変わる） =====
-- 誤答: ステータス除外なし
SELECT SUM(quantity * price) AS sales_naive FROM order_items;
-- 正（本書の口径）: cancelled/returned除外
SELECT SUM(oi.quantity * oi.price) AS sales
FROM order_items oi JOIN orders o ON oi.order_id = o.id
WHERE o.status NOT IN ('cancelled', 'returned');

-- ===== ケース2: リピート率（JOIN粒度誤りで多重カウント） =====
-- 誤答: 明細と結合してから数える（1注文の明細行数だけ「購入回数」が増える）
SELECT count(*) AS users,
       count(*) FILTER (WHERE n >= 2) AS repeat_users_inflated
FROM (SELECT o.user_id, count(*) AS n
      FROM orders o JOIN order_items oi ON oi.order_id = o.id
      WHERE o.ordered_at >= now() - interval '365 days'
      GROUP BY o.user_id) s;
-- 正（本書の口径）: 取消・返品を除き、購入日（JST）に丸めてからユーザーごとに数える
WITH user_days AS (
    SELECT DISTINCT user_id, (ordered_at AT TIME ZONE 'Asia/Tokyo')::date AS d FROM orders
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

-- ===== ケース3: 在庫切れ（在庫0と未設定の混同） =====
-- 在庫0（補充が必要）と在庫行なし（取扱対象外）を分けて数える
SELECT count(*) FILTER (WHERE i.stock = 0) AS out_of_stock,
       count(*) FILTER (WHERE i.product_id IS NULL) AS no_inventory_row
FROM products p LEFT JOIN inventory i ON i.product_id = p.id
WHERE p.deleted_at IS NULL;
