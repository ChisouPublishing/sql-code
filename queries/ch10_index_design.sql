-- ch10_index_design.sql — 索引設計と最適化（第10章）
-- codes/sql-code/queries/ch10_index_design.sql@v1.2.2
-- 前提: 性能比較用DB sakura_xl（orders 1000万・behavior_logs 1000万）。
--   psql -d sakura_xl -f queries/ch10_index_design.sql
--   既定DB（sakura_market、10万行級）でも動くが、索引の効き目は小さく見える。
-- 本番適用は CREATE INDEX CONCURRENTLY（表を書き込みロックしない）。ここでは学習用に通常の CREATE INDEX。
-- 大きい表に索引を作るので、sakura_xl では全体で数分かかる。

SET search_path TO sakura, public;

-- ===== 0. 作る前に、今ある索引を見る（重複を作らない） =====
SELECT tablename, indexname, indexdef FROM pg_indexes
WHERE schemaname = 'sakura' AND tablename IN ('orders', 'order_items', 'behavior_logs')
ORDER BY tablename, indexname;

-- ===== 1. 種類（B-treeが既定。Hash/GIN/GiST/BRINは用途別） =====
-- Hash（等価検索だけ）: 追跡番号で発送を引く。範囲検索・並べ替えには使えない。
-- 注: users.email には UNIQUE 制約の B-tree がすでにあるので、そこに Hash を足すと重複になる
CREATE INDEX IF NOT EXISTS idx_ch10_shipments_tracking_hash ON shipments USING hash (tracking_number);
EXPLAIN (ANALYZE, BUFFERS)
SELECT order_id, carrier FROM shipments
WHERE tracking_number = (SELECT tracking_number FROM shipments LIMIT 1);

-- GIN（部分一致検索）: pg_trgm で商品名の「〜を含む」検索に索引を効かせる
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE INDEX IF NOT EXISTS idx_ch10_products_name_gin ON products USING gin (name_ja gin_trgm_ops);
EXPLAIN (ANALYZE, BUFFERS)
SELECT sku, name_ja FROM products WHERE name_ja LIKE '%M1234%';

-- BRIN（追記型の時系列に、ごく小さい索引）: 行動ログは時刻順に追記されるので、
-- 「ブロックの範囲ごとの最小・最大時刻」だけで読む範囲を絞れる
CREATE INDEX IF NOT EXISTS idx_ch10_behavior_created_brin ON behavior_logs USING brin (created_at);
SELECT attname, correlation FROM pg_stats      -- 1に近いほど物理順と値の順がそろっている（BRIN向き）
WHERE schemaname = 'sakura' AND tablename = 'behavior_logs' AND attname = 'created_at';
EXPLAIN (ANALYZE, BUFFERS)
SELECT action, count(*) FROM behavior_logs
WHERE created_at >= now() - interval '1 day'
GROUP BY action;
-- 大きさの比較: BRIN と、同じ表の B-tree（基礎索引）
SELECT indexrelname, pg_size_pretty(pg_relation_size(indexrelid)) AS size
FROM pg_stat_user_indexes
WHERE schemaname = 'sakura' AND relname = 'behavior_logs'
ORDER BY pg_relation_size(indexrelid) DESC;

-- ===== 2. 複合索引（等価→範囲→ソートの順） =====
-- 「ある会員の最近の注文」: user_id（等価）→ ordered_at（範囲・並べ替え）
CREATE INDEX IF NOT EXISTS idx_ch10_orders_user_ordered ON orders (user_id, ordered_at DESC);
EXPLAIN (ANALYZE, BUFFERS)
SELECT id, status, amount, ordered_at FROM orders
WHERE user_id = (SELECT user_id FROM orders ORDER BY ordered_at DESC LIMIT 1)
ORDER BY ordered_at DESC LIMIT 10;
-- 「カテゴリ内を価格順に」: category_id（等価）→ price（範囲・並べ替え）
CREATE INDEX IF NOT EXISTS idx_ch10_products_cat_price ON products (category_id, price);

-- ===== 3. カバリング索引（INCLUDEでIndex Only Scan） =====
-- 会員ごとの注文金額・日時を、表を読まずに索引だけで返す
CREATE INDEX IF NOT EXISTS idx_ch10_orders_cover
    ON orders (user_id) INCLUDE (amount, ordered_at);
VACUUM (ANALYZE) orders;   -- 可視性マップを更新（Index Only Scan の前提）
EXPLAIN (ANALYZE, BUFFERS)
SELECT user_id, amount, ordered_at FROM orders ORDER BY user_id LIMIT 100;
-- 「Index Only Scan using idx_ch10_orders_cover」と「Heap Fetches: 0」になれば成功

-- ===== 4. 部分索引（WHERE付き。now() のように値が変わる条件は書けない） =====
-- 未決済（ordered）の注文を古い順に（督促・自動取消の対象探し）。
-- 1000万件のうち数千件だけを索引に入れるので、ごく小さい
CREATE INDEX IF NOT EXISTS idx_ch10_orders_open
    ON orders (ordered_at) WHERE status = 'ordered';
EXPLAIN (ANALYZE, BUFFERS)
SELECT id, user_id, amount, ordered_at FROM orders
WHERE status = 'ordered'
ORDER BY ordered_at LIMIT 100;
SELECT pg_size_pretty(pg_relation_size('idx_ch10_orders_open')) AS partial_index_size,
       pg_size_pretty(pg_relation_size('idx_orders_ordered_at')) AS full_index_size;

-- ===== 5. PG18 スキップスキャン（先頭列を指定しなくても複合B-treeが効く） =====
-- 効くのは「先頭列の種類が少ない」とき。status は6種類しかないので、
-- (status, ordered_at) の索引を status ごとにたどれば、ordered_at の範囲を引ける
CREATE INDEX IF NOT EXISTS idx_ch10_orders_status_ordered ON orders (status, ordered_at);
ANALYZE orders;
-- 同じ条件には単独の索引 idx_orders_ordered_at もあり、ふつうはそちらが選ばれる。
-- スキップスキャンだけを見るため、トランザクションの中で単独索引を一時的に消して確かめる
-- （DROP INDEX も ROLLBACK で元に戻る。ただし実行中は orders 全体がロックされるので、共用DBでは避ける）
BEGIN;
DROP INDEX idx_orders_ordered_at;
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM orders
WHERE ordered_at >= now() - interval '1 hour';
ROLLBACK;
-- 計画が「Index Only Scan using idx_ch10_orders_status_ordered」で、
-- 「Index Searches:」が数回（status の種類ぶん前後）なら、先頭列の値ごとに飛ばして読んでいる。
-- 反対に、先頭列 user_id の種類が多い (user_id, ordered_at) では、スキップスキャンは割に合わず使われない

-- ===== 6. AI提案の検証観点（企画 §10.7–10.8） =====
-- 列順序が等価→範囲→ソートか / 既存と重複していないか / 更新コストを見ているか
-- 重複の例: (user_id, created_at DESC) は基礎索引 (user_id, created_at) と向きが違うだけ。
--   B-tree は逆向きにもたどれるので、「user_id = ? ORDER BY created_at DESC」は基礎索引で足りる。
--   v1.1.1 まではここで idx_ch10_behavior_user_desc / product_desc を作っていたが、重複なので作らない。
EXPLAIN (ANALYZE, BUFFERS)
SELECT action, created_at FROM behavior_logs
WHERE user_id = (SELECT user_id FROM behavior_logs WHERE user_id IS NOT NULL LIMIT 1)
ORDER BY created_at DESC LIMIT 20;
-- → Index Scan Backward using idx_behavior_logs_user_time（並べ替えなし）

-- 重複・包含の候補を洗い出す（同じ表で、先頭列が同じ索引の組）
SELECT a.indrelid::regclass AS tbl,
       a.indexrelid::regclass AS index_a, b.indexrelid::regclass AS index_b,
       pg_get_indexdef(a.indexrelid) AS def_a, pg_get_indexdef(b.indexrelid) AS def_b
FROM pg_index a
JOIN pg_index b ON b.indrelid = a.indrelid AND b.indexrelid > a.indexrelid
               AND b.indkey[0] = a.indkey[0]
JOIN pg_class t ON t.oid = a.indrelid
WHERE t.relnamespace = 'sakura'::regnamespace
ORDER BY 1, 2;

-- ===== 7. 未使用索引の検出 → DROP 検討 =====
SELECT relname, indexrelname, idx_scan, pg_size_pretty(pg_relation_size(indexrelid)) AS size
FROM pg_stat_user_indexes
WHERE schemaname = 'sakura' AND idx_scan = 0
ORDER BY pg_relation_size(indexrelid) DESC, relname, indexrelname;

-- ===== 8. 最終設計の要点（Sakura Market） =====
-- orders(user_id, ordered_at DESC)、order_items(product_id) INCLUDE (order_id, quantity, price)、
-- behavior_logs は基礎索引 (user_id, created_at)・(product_id, created_at) ＋ BRIN(created_at)、
-- reviews(product_id)、shipments(shipped_at)、coupons(expires_at)、未決済の部分索引。
-- 注: order_items(product_id) INCLUDE (...) を作ると、基礎索引 idx_order_items_product は
--     先頭列が同じなので不要になる（DROP 候補。6. の重複一覧に出る）
CREATE INDEX IF NOT EXISTS idx_ch10_items_product_cover
    ON order_items (product_id) INCLUDE (order_id, quantity, price);
CREATE INDEX IF NOT EXISTS idx_ch10_shipments_shipped ON shipments (shipped_at);
CREATE INDEX IF NOT EXISTS idx_ch10_coupons_expires ON coupons (expires_at);
