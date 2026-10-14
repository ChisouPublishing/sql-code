-- verify_all.sql — 整合性チェック一式（第5章 §5.11、第8章）
-- codes/sql-code/checks/verify_all.sql@v1.2.2
-- 使い方: make verify（既定DB）/ make verify DB=sakura_xl
--         psql -U sakura -d sakura_market -f checks/verify_all.sql
-- 期待: result 列がすべて OK（孤児・矛盾・違反は0件）。最後の summary で NG 件数を数える。
-- 大規模（sakura_xl）では全表を読むので数分かかる。

SET search_path TO sakura, public;

CREATE TEMP TABLE verify_results (
    seq serial, check_name text, actual bigint, expected text, result text
);

-- 1. コア18テーブルが揃っているか（章クエリが作る追加表は別にINFO表示）
CREATE TEMP TABLE core_tables(t) AS VALUES
    ('users'), ('addresses'), ('sellers'), ('categories'), ('products'),
    ('inventory'), ('inventory_logs'), ('coupons'), ('campaigns'),
    ('campaign_coupons'), ('orders'), ('order_status_histories'), ('order_items'),
    ('payments'), ('shipments'), ('returns'), ('reviews'), ('behavior_logs');

INSERT INTO verify_results (check_name, actual, expected, result)
SELECT 'core_tables', count(*), '18',
       CASE WHEN count(*) = 18 THEN 'OK' ELSE 'NG' END
FROM core_tables c
WHERE EXISTS (SELECT 1 FROM information_schema.tables t
              WHERE t.table_schema = 'sakura' AND t.table_name = c.t);

-- 章クエリが作る追加表（pgss_snapshots/ch11、daily+today/ch14、audit_logs/ch15 など）
SELECT table_name AS extra_table FROM information_schema.tables
WHERE table_schema = 'sakura' AND table_type = 'BASE TABLE'
  AND table_name NOT IN (SELECT t FROM core_tables)
ORDER BY table_name;

-- 2. 行数（全18表）
SELECT 'row_counts' AS check_name, t AS tbl, c AS cnt FROM (
    SELECT 'users' t, count(*) c FROM users UNION ALL
    SELECT 'addresses', count(*) FROM addresses UNION ALL
    SELECT 'sellers', count(*) FROM sellers UNION ALL
    SELECT 'categories', count(*) FROM categories UNION ALL
    SELECT 'products', count(*) FROM products UNION ALL
    SELECT 'inventory', count(*) FROM inventory UNION ALL
    SELECT 'inventory_logs', count(*) FROM inventory_logs UNION ALL
    SELECT 'coupons', count(*) FROM coupons UNION ALL
    SELECT 'campaigns', count(*) FROM campaigns UNION ALL
    SELECT 'campaign_coupons', count(*) FROM campaign_coupons UNION ALL
    SELECT 'orders', count(*) FROM orders UNION ALL
    SELECT 'order_status_histories', count(*) FROM order_status_histories UNION ALL
    SELECT 'order_items', count(*) FROM order_items UNION ALL
    SELECT 'payments', count(*) FROM payments UNION ALL
    SELECT 'shipments', count(*) FROM shipments UNION ALL
    SELECT 'returns', count(*) FROM returns UNION ALL
    SELECT 'reviews', count(*) FROM reviews UNION ALL
    SELECT 'behavior_logs', count(*) FROM behavior_logs
) s ORDER BY tbl;

-- 3. 外部キー孤児（すべて0件期待）。制約が今も効いているかの確認
INSERT INTO verify_results (check_name, actual, expected, result)
SELECT name, n, '0', CASE WHEN n = 0 THEN 'OK' ELSE 'NG' END FROM (
    SELECT 'fk_orders_user' AS name, count(*) AS n
    FROM orders o LEFT JOIN users u ON o.user_id = u.id WHERE u.id IS NULL
    UNION ALL
    SELECT 'fk_items_order', count(*)
    FROM order_items oi LEFT JOIN orders o ON oi.order_id = o.id WHERE o.id IS NULL
    UNION ALL
    SELECT 'fk_items_product', count(*)
    FROM order_items oi LEFT JOIN products p ON oi.product_id = p.id WHERE p.id IS NULL
    UNION ALL
    SELECT 'fk_products_category', count(*)
    FROM products p LEFT JOIN categories c ON p.category_id = c.id WHERE c.id IS NULL
    UNION ALL
    SELECT 'fk_behavior_user', count(*)
    FROM behavior_logs b LEFT JOIN users u ON b.user_id = u.id
    WHERE b.user_id IS NOT NULL AND u.id IS NULL
    UNION ALL
    SELECT 'fk_histories_order', count(*)
    FROM order_status_histories h LEFT JOIN orders o ON h.order_id = o.id WHERE o.id IS NULL
) s;

-- 3b. 索引のない外部キー列（第5章の洗い出し。v1.2.0 で0本にした）
INSERT INTO verify_results (check_name, actual, expected, result)
SELECT 'fk_without_index', count(*), '0', CASE WHEN count(*) = 0 THEN 'OK' ELSE 'NG' END
FROM pg_constraint c
WHERE c.contype = 'f'
  AND c.connamespace = 'sakura'::regnamespace
  AND c.conrelid::regclass::text IN (SELECT t FROM core_tables)
  AND NOT EXISTS (
      SELECT 1 FROM pg_index i
      WHERE i.indrelid = c.conrelid AND i.indkey[0] = c.conkey[1]);

-- 4. 日付の論理矛盾（すべて0件期待）
INSERT INTO verify_results (check_name, actual, expected, result)
SELECT name, n, '0', CASE WHEN n = 0 THEN 'OK' ELSE 'NG' END FROM (
    SELECT 'date_shipped_before_ordered' AS name, count(*) AS n
    FROM shipments s JOIN orders o ON s.order_id = o.id
    WHERE s.shipped_at IS NOT NULL AND s.shipped_at < o.ordered_at
    UNION ALL
    SELECT 'date_delivered_before_shipped', count(*)
    FROM shipments WHERE delivered_at IS NOT NULL AND delivered_at < shipped_at
    UNION ALL
    SELECT 'date_ordered_before_signup', count(*)
    FROM orders o JOIN users u ON u.id = o.user_id WHERE o.ordered_at < u.created_at
    UNION ALL
    SELECT 'date_in_future', count(*)
    FROM order_status_histories WHERE changed_at > now()
) s;

-- 5. 業務ルール（すべて0件期待）
INSERT INTO verify_results (check_name, actual, expected, result)
SELECT name, n, '0', CASE WHEN n = 0 THEN 'OK' ELSE 'NG' END FROM (
    SELECT 'rule_negative_stock' AS name, count(*) AS n FROM inventory WHERE stock < 0
    UNION ALL
    SELECT 'rule_negative_amount', count(*) FROM orders WHERE amount < 0
    UNION ALL
    SELECT 'rule_rating_range', count(*) FROM reviews WHERE rating NOT BETWEEN 1 AND 5
    -- 金額の内訳: 請求額 = 小計 - 値引き + 送料（CHECK 制約の再確認）
    UNION ALL
    SELECT 'rule_amount_breakdown', count(*) FROM orders
    WHERE amount <> subtotal - discount_amount + shipping_fee
    -- 小計 = 明細の 数量×単価 の合計
    UNION ALL
    SELECT 'rule_subtotal_equals_items', count(*)
    FROM orders o
    LEFT JOIN (SELECT order_id, sum(quantity * price) AS s FROM order_items GROUP BY order_id) i
      ON i.order_id = o.id
    WHERE o.subtotal IS DISTINCT FROM i.s
    -- 送料ルール: 小計5000円未満は500円、以上は0円
    UNION ALL
    SELECT 'rule_shipping_fee', count(*) FROM orders
    WHERE shipping_fee <> CASE WHEN subtotal < 5000 THEN 500 ELSE 0 END
    -- 値引きはクーポンを使った注文だけ
    UNION ALL
    SELECT 'rule_discount_without_coupon', count(*) FROM orders
    WHERE coupon_id IS NULL AND discount_amount <> 0
    -- 決済額 = 請求額（照合）
    UNION ALL
    SELECT 'rule_payment_amount_mismatch', count(*)
    FROM payments p JOIN orders o ON o.id = p.order_id WHERE p.amount <> o.amount
    -- 未決済（ordered）以外の注文には決済が1件ある
    UNION ALL
    SELECT 'rule_payment_missing', count(*) FROM orders o
    WHERE o.status <> 'ordered' AND NOT EXISTS (SELECT 1 FROM payments p WHERE p.order_id = o.id)
    -- 発送済み以降の注文には発送が1件ある
    UNION ALL
    SELECT 'rule_shipment_missing', count(*) FROM orders o
    WHERE o.status IN ('shipped', 'delivered', 'returned')
      AND NOT EXISTS (SELECT 1 FROM shipments s WHERE s.order_id = o.id)
    -- クーポンの使用回数 = 取り消されていない注文での使用数、かつ上限以内
    UNION ALL
    SELECT 'rule_coupon_used_count', count(*)
    FROM coupons c
    WHERE c.used_count <> (SELECT count(*) FROM orders o
                           WHERE o.coupon_id = c.id AND o.status <> 'cancelled')
       OR (c.max_uses IS NOT NULL AND c.used_count > c.max_uses)
    -- 既定住所は1人ちょうど1件
    UNION ALL
    SELECT 'rule_default_address', count(*)
    FROM users u
    WHERE (SELECT count(*) FROM addresses a WHERE a.user_id = u.id AND a.is_default) <> 1
    -- 在庫数 = 在庫変動履歴の change の合計（造数では初回入荷のみ）
    UNION ALL
    SELECT 'rule_inventory_matches_logs', count(*)
    FROM inventory i
    LEFT JOIN (SELECT product_id, sum(change) AS s FROM inventory_logs GROUP BY product_id) l
      ON l.product_id = i.product_id
    WHERE i.stock <> COALESCE(l.s, 0)
    -- 返品の返金額は請求額以下
    UNION ALL
    SELECT 'rule_refund_over_amount', count(*)
    FROM returns r JOIN orders o ON o.id = r.order_id WHERE r.refund_amount > o.amount
) s;

-- 6. 状態履歴の整合（すべて0件期待）
--    最後の履歴の to_status = 今の状態、履歴は前の行の to_status から続く、最初の行は from_status NULL
INSERT INTO verify_results (check_name, actual, expected, result)
SELECT name, n, '0', CASE WHEN n = 0 THEN 'OK' ELSE 'NG' END FROM (
    SELECT 'hist_last_equals_status' AS name, count(*) AS n
    FROM orders o
    LEFT JOIN (SELECT DISTINCT ON (order_id) order_id, to_status
               FROM order_status_histories ORDER BY order_id, changed_at DESC) h
      ON h.order_id = o.id
    WHERE h.to_status IS DISTINCT FROM o.status
    UNION ALL
    SELECT 'hist_chain_broken', count(*)
    FROM (SELECT from_status,
                 lag(to_status) OVER (PARTITION BY order_id ORDER BY changed_at) AS prev
          FROM order_status_histories) s
    WHERE from_status IS DISTINCT FROM prev
) s;

-- 7. 値の偏り（造数の縮退を見抜く。v1.1.1 で products.category_id が1値に縮退していた）
--    種類数（actual = distinct_values）が2以上で、最多値の割合（top_share_pct）が50%未満であること
INSERT INTO verify_results (check_name, actual, expected, result)
SELECT 'skew_' || col, distinct_values, '種類>1 かつ 最多値<50%',
       CASE WHEN top_share_pct < 50 AND distinct_values > 1 THEN 'OK' ELSE 'NG' END
FROM (
    SELECT 'products.category_id' AS col, count(*) AS distinct_values,
           100.0 * max(cnt) / sum(cnt) AS top_share_pct
    FROM (SELECT category_id, count(*) AS cnt FROM products GROUP BY category_id) s
    UNION ALL
    SELECT 'products.seller_id', count(*), 100.0 * max(cnt) / sum(cnt)
    FROM (SELECT seller_id, count(*) AS cnt FROM products GROUP BY seller_id) s
    UNION ALL
    SELECT 'orders.user_id', count(*), 100.0 * max(cnt) / sum(cnt)
    FROM (SELECT user_id, count(*) AS cnt FROM orders GROUP BY user_id) s
    UNION ALL
    SELECT 'order_items.product_id', count(*), 100.0 * max(cnt) / sum(cnt)
    FROM (SELECT product_id, count(*) AS cnt FROM order_items GROUP BY product_id) s
    -- orders.status は delivered が大半なのが正常なので、ここでは判定せず下の表で目視する
) t;

-- 偏りの詳細（目視用）
SELECT col, distinct_values, round(top_share_pct, 2) AS top_share_pct FROM (
    SELECT 'products.category_id' AS col, count(*) AS distinct_values,
           100.0 * max(cnt) / sum(cnt) AS top_share_pct
    FROM (SELECT category_id, count(*) AS cnt FROM products GROUP BY category_id) s
    UNION ALL
    SELECT 'products.seller_id', count(*), 100.0 * max(cnt) / sum(cnt)
    FROM (SELECT seller_id, count(*) AS cnt FROM products GROUP BY seller_id) s
    UNION ALL
    SELECT 'orders.user_id', count(*), 100.0 * max(cnt) / sum(cnt)
    FROM (SELECT user_id, count(*) AS cnt FROM orders GROUP BY user_id) s
    UNION ALL
    SELECT 'order_items.product_id', count(*), 100.0 * max(cnt) / sum(cnt)
    FROM (SELECT product_id, count(*) AS cnt FROM order_items GROUP BY product_id) s
) t ORDER BY top_share_pct DESC;

-- 注文状態の内訳・明細行数の分布・クーポン利用（目視用）
SELECT status, count(*) AS orders, round(100.0 * count(*) / sum(count(*)) OVER (), 2) AS pct
FROM orders GROUP BY status ORDER BY orders DESC;
SELECT lines, count(*) AS orders FROM (
    SELECT order_id, count(*) AS lines FROM order_items GROUP BY order_id) s
GROUP BY lines ORDER BY lines;
SELECT count(*) AS orders, count(coupon_id) AS with_coupon,
       count(*) FILTER (WHERE shipping_fee > 0) AS with_shipping_fee,
       round(avg(amount)) AS avg_amount
FROM orders;

-- 8. 登録日の偏り（目視確認：特定日に集中していないこと）
SELECT date_trunc('day', created_at)::date AS day, count(*) AS cnt
FROM users GROUP BY 1 ORDER BY cnt DESC LIMIT 5;

-- 9. 容量（大きい順）
SELECT c.relname AS tbl, pg_size_pretty(pg_total_relation_size(c.oid)) AS size
FROM pg_class c
WHERE c.relnamespace = 'sakura'::regnamespace AND c.relkind = 'r'
ORDER BY pg_total_relation_size(c.oid) DESC LIMIT 10;
SELECT pg_size_pretty(pg_database_size(current_database())) AS database_size;

-- 結果一覧と要約（NG が0件ならすべて合格）
SELECT check_name, actual, expected, result FROM verify_results ORDER BY seq;
SELECT count(*) AS checks,
       count(*) FILTER (WHERE result = 'NG') AS ng,
       CASE WHEN count(*) FILTER (WHERE result = 'NG') = 0 THEN 'ALL OK' ELSE 'NG あり' END AS summary
FROM verify_results;
