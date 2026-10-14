-- ch09_explain_5.sql — 遅い5クエリの実行計画と改善（第9章）
-- codes/sql-code/queries/ch09_explain_5.sql@v1.2.2
-- 前提: 既定DB sakura_market（small＋medium。小規模だけでは差が出にくい）。
-- EXPLAIN (ANALYZE, BUFFERS) で実測する。改善用INDEXは ch10 と重複しない名前にする。
SET search_path TO sakura, public;

-- Q1: ランク絞り込み（Seq Scan → 部分索引）
EXPLAIN (ANALYZE, BUFFERS)
SELECT id, display_name FROM users WHERE rank = 'gold' LIMIT 100;
-- 改善
CREATE INDEX IF NOT EXISTS idx_ch09_users_gold ON users (id) WHERE rank = 'gold';
EXPLAIN (ANALYZE, BUFFERS)
SELECT id, display_name FROM users WHERE rank = 'gold' LIMIT 100;

-- Q2: 注文×ユーザーの結合（users側の絞り込みが Seq Scan → rank の索引で先に絞る）
-- 結合列 orders.user_id には基礎索引 idx_orders_user（03_indexes.sql）がすでにある。
-- v1.1.1 まではここで同じ列に idx_ch09_orders_user を作っていたが、同じ働きの索引が2本になる
-- （書き込みが遅くなるだけ）ので v1.2.0 で削除した。作る前に既存の索引を確かめる（第10章）。
SELECT indexname, indexdef FROM pg_indexes
WHERE schemaname = 'sakura' AND tablename = 'orders' AND indexdef LIKE '%(user_id)%';
EXPLAIN (ANALYZE, BUFFERS)
SELECT o.id, u.display_name, o.amount
FROM orders o JOIN users u ON o.user_id = u.id
WHERE u.rank = 'platinum' LIMIT 100;
-- 改善
CREATE INDEX IF NOT EXISTS idx_ch09_users_rank ON users (rank);
EXPLAIN (ANALYZE, BUFFERS)
SELECT o.id, u.display_name, o.amount
FROM orders o JOIN users u ON o.user_id = u.id
WHERE u.rank = 'platinum' LIMIT 100;

-- Q3: 最新10件（Seq Scan＋Sort → 順序索引で Index Scan Backward）
-- 行動ログ（約100万行）の最新10件。created_at の索引が無いと、全行を読んで並べ替える。
-- 注: 注文の新着順（orders.ordered_at）は基礎索引 idx_orders_ordered_at がすでに効く。
--     B-tree は逆向きにもたどれる（Index Scan Backward）ので、DESC 向きの索引を別に作る必要はない。
EXPLAIN (ANALYZE, BUFFERS)
SELECT id, action, created_at FROM behavior_logs ORDER BY created_at DESC LIMIT 10;
-- 改善
CREATE INDEX IF NOT EXISTS idx_ch09_behavior_created ON behavior_logs (created_at);
EXPLAIN (ANALYZE, BUFFERS)
SELECT id, action, created_at FROM behavior_logs ORDER BY created_at DESC LIMIT 10;

-- Q4: N+1（ユーザー100人分の注文数を1行ずつ → 1回のJOINに集約）
-- 悪い例のイメージ（アプリケーション側で100回発行）:
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM orders WHERE user_id = (SELECT id FROM users LIMIT 1);
-- 改善（100人分を一括）
EXPLAIN (ANALYZE, BUFFERS)
SELECT u.id, count(o.id) AS orders
FROM (SELECT id FROM users LIMIT 100) u
LEFT JOIN orders o ON o.user_id = u.id
GROUP BY u.id;

-- Q5: カテゴリ別売上4JOIN（HashAggregate大量行 → 集計はマテビュー化。第12・14章へ）
EXPLAIN (ANALYZE, BUFFERS)
SELECT c.name, SUM(oi.quantity * oi.price) AS sales
FROM order_items oi
JOIN orders o ON oi.order_id = o.id
JOIN products p ON oi.product_id = p.id
JOIN categories c ON p.category_id = c.id
WHERE o.status NOT IN ('cancelled', 'returned')
GROUP BY c.name;

-- 読みどころ: cost（開始..終了）、rows推定 vs actual rows の乖離（→ANALYZE）、
-- Buffers: hit/read、loops、Heap Fetches。AIへの貼り付けはこの出力をそのまま使う（第9章 §9.13）。
