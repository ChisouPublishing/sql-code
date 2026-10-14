-- ch12_tuning.sql — パフォーマンスチューニング実践（第12章）
-- codes/sql-code/queries/ch12_tuning.sql@v1.2.2
-- 前提: 性能比較用DB sakura_xl（orders 1000万・order_items 約3000万・behavior_logs 1000万）。
--   psql -d sakura_xl -f queries/ch12_tuning.sql
--   既定DB（sakura_market）でも動く。規模が小さいと、書き換えの差はほとんど出ない（第12章 §10）。
-- 実行時間は環境で変わる。本書の実測は VALIDATION.md と第12章に記録する（ここに目標値は書かない）。

SET search_path TO sakura, public;

-- ===== 03 書き換え①: 相関サブクエリ → JOIN =====
-- 悪い例: ユーザーごとに注文数を相関サブクエリで
EXPLAIN
SELECT u.id, u.display_name,
    (SELECT count(*) FROM orders o WHERE o.user_id = u.id) AS orders
FROM users u LIMIT 100;
-- 良い例: JOIN して集計。GROUP BY は主キー u.id で（表示名が同じ別人を1行にまとめない）
EXPLAIN
SELECT u.id, u.display_name, count(o.id) AS orders
FROM users u LEFT JOIN orders o ON o.user_id = u.id
GROUP BY u.id, u.display_name LIMIT 100;

-- ===== 03 書き換え②: IN → EXISTS / NOT IN → NOT EXISTS（NULL安全） =====
-- 悪い例（NOT IN は副問合せに NULL が1つでもあると0行になる）
EXPLAIN
SELECT id, display_name FROM users WHERE id NOT IN (SELECT user_id FROM orders);
-- 良い例
EXPLAIN
SELECT u.id, u.display_name FROM users u WHERE NOT EXISTS (
    SELECT 1 FROM orders o WHERE o.user_id = u.id);

-- ===== 03 書き換え③: CTEの物化制御 =====
EXPLAIN
WITH recent_orders AS MATERIALIZED (
    SELECT * FROM orders WHERE ordered_at >= now() - interval '30 days'
)
SELECT count(*) FROM recent_orders;
EXPLAIN
WITH recent_orders AS NOT MATERIALIZED (
    SELECT * FROM orders WHERE ordered_at >= now() - interval '30 days'
)
SELECT count(*) FROM recent_orders;

-- ===== 03 書き換え④: 先絞りCTE＋集計粒度下げ =====
-- 悪い例の形: 全期間JOINしてから絞る（多くの場合プランナが絞り込みを先に回すので、計画で確かめる）
EXPLAIN
SELECT c.name, SUM(oi.quantity * oi.price)
FROM order_items oi
JOIN orders o ON oi.order_id = o.id
JOIN products p ON oi.product_id = p.id
JOIN categories c ON p.category_id = c.id
WHERE o.ordered_at >= now() - interval '30 days'
  AND o.status NOT IN ('cancelled', 'returned')
GROUP BY c.name;
-- 良い例: 先に注文を絞る
EXPLAIN
WITH target_orders AS (
    SELECT id FROM orders
    WHERE ordered_at >= now() - interval '30 days'
      AND status NOT IN ('cancelled', 'returned')
)
SELECT c.name, SUM(oi.quantity * oi.price)
FROM target_orders o
JOIN order_items oi ON oi.order_id = o.id
JOIN products p ON oi.product_id = p.id
JOIN categories c ON p.category_id = c.id
GROUP BY c.name;

-- ===== 05 パラメータ（確認と一時変更） =====
SHOW work_mem;               -- 16MB（compose既定）
SHOW shared_buffers;         -- 256MB（compose既定）
SHOW effective_cache_size;
-- 06 PG18の非同期I/O: 本書の compose は worker（macOS の Docker では io_uring を使えない）。
-- Linux サーバーでは io_uring も選べる（変えるには再起動が要る）
SHOW io_method;              -- worker（compose既定）
-- 集計クエリだけ一時的に増やす（トランザクション限り）
-- BEGIN; SET LOCAL work_mem = '128MB'; ... ; COMMIT;

-- ===== 07 パーティション（behavior_logs の月次分割デモ） =====
-- パーティション表の主キー・一意制約には、分割の列（created_at）を含める必要がある。
-- そのため主キーは (id, created_at)。LIKE behavior_logs INCLUDING ALL で PK(id) を写すとエラーになる。
-- デモは BEGIN 〜 ROLLBACK の中で行い、DBに何も残さない。
-- 月の境界は「今」から計算する（データは投入した日を基準に過去へ散っているため）
SELECT to_char(date_trunc('month', now()) - interval '3 months', 'YYYY-MM-DD') AS m0,
       to_char(date_trunc('month', now()) - interval '2 months', 'YYYY-MM-DD') AS m1,
       to_char(date_trunc('month', now()) - interval '1 month', 'YYYY-MM-DD') AS m2,
       to_char(date_trunc('month', now()), 'YYYY-MM-DD') AS m3 \gset
BEGIN;
CREATE TABLE behavior_logs_p (
    id uuid NOT NULL DEFAULT uuidv7(),
    user_id uuid,
    product_id uuid,
    action varchar(30) NOT NULL,
    search_keyword varchar(255),
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (id, created_at)
) PARTITION BY RANGE (created_at);
CREATE TABLE behavior_logs_p_m0 PARTITION OF behavior_logs_p FOR VALUES FROM (:'m0') TO (:'m1');
CREATE TABLE behavior_logs_p_m1 PARTITION OF behavior_logs_p FOR VALUES FROM (:'m1') TO (:'m2');
CREATE TABLE behavior_logs_p_m2 PARTITION OF behavior_logs_p FOR VALUES FROM (:'m2') TO (:'m3');
-- 3か月分から約3%を標本として入れる
INSERT INTO behavior_logs_p (id, user_id, product_id, action, search_keyword, created_at)
SELECT id, user_id, product_id, action, search_keyword, created_at
FROM behavior_logs TABLESAMPLE SYSTEM (3) REPEATABLE (42)
WHERE created_at >= :'m0' AND created_at < :'m3';
ANALYZE behavior_logs_p;
-- 1か月の中だけを読む → そのパーティションだけを Scan（プルーニング）
--   境界が式（timestamptz + interval）なので計画時には決まらず、実行時に絞る。
--   Append は残り、「Subplans Removed: 2」と出る（定数で書けば計画時に省かれ、Append も消える）
EXPLAIN (ANALYZE)
SELECT count(*) FROM behavior_logs_p
WHERE created_at >= :'m1'::timestamptz + interval '9 days'
  AND created_at < :'m1'::timestamptz + interval '19 days';
-- 2か月にまたがる → Append の下に2つ（「Subplans Removed: 1」）
EXPLAIN (ANALYZE)
SELECT count(*) FROM behavior_logs_p
WHERE created_at >= :'m1'::timestamptz + interval '20 days'
  AND created_at < :'m2'::timestamptz + interval '10 days';
-- 古い月を消す: DELETE ではなく切り離して DROP（一瞬で終わり、表が膨らまない）
ALTER TABLE behavior_logs_p DETACH PARTITION behavior_logs_p_m0;
DROP TABLE behavior_logs_p_m0;
ROLLBACK;

-- ===== 09 マテビュー（集計結果の保存） =====
-- 全期間のカテゴリ別売上。一意索引は category_id（名前は親が違えば重複しうる）
CREATE MATERIALIZED VIEW IF NOT EXISTS mv_category_sales AS
SELECT c.id AS category_id,
       c.name AS category_name,
       SUM(oi.quantity * oi.price)::bigint AS total_sales,
       count(DISTINCT o.id)::int AS order_count,
       count(DISTINCT o.user_id)::int AS customer_count,
       now() AS refreshed_at          -- REFRESH した時刻が保存される
FROM orders o
JOIN order_items oi ON oi.order_id = o.id
JOIN products p ON oi.product_id = p.id
JOIN categories c ON p.category_id = c.id
WHERE o.status NOT IN ('cancelled', 'returned')
GROUP BY c.id, c.name;
CREATE UNIQUE INDEX IF NOT EXISTS uq_mv_category_sales
    ON mv_category_sales (category_id);
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM mv_category_sales ORDER BY total_sales DESC;
-- 更新（一意索引があるので、参照を止めずに更新できる）
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_category_sales;

-- ===== 10 完全ケース: 直近30日のカテゴリ別売上を段階的に改善する =====
-- 各段階の EXPLAIN (ANALYZE, BUFFERS) を保存し、実行時間（3回の中央値）を記録する。
-- 結果がすべて同じであること（数字が変わらないこと）も確かめる。
-- ステップ0: 元のSQL
EXPLAIN (ANALYZE, BUFFERS)
SELECT c.name AS category_name,
       SUM(oi.quantity * oi.price) AS total_sales,
       COUNT(DISTINCT o.id) AS order_count,
       COUNT(DISTINCT o.user_id) AS customer_count
FROM order_items oi
JOIN orders o ON oi.order_id = o.id
JOIN products p ON oi.product_id = p.id
JOIN categories c ON p.category_id = c.id
WHERE o.ordered_at >= now() - interval '30 days'
  AND o.status NOT IN ('cancelled', 'returned')
GROUP BY c.name
ORDER BY total_sales DESC;

-- ステップ1: 先に絞るCTE
EXPLAIN (ANALYZE, BUFFERS)
WITH recent_orders AS (
    SELECT id, user_id FROM orders
    WHERE ordered_at >= now() - interval '30 days'
      AND status NOT IN ('cancelled', 'returned')
)
SELECT c.name AS category_name,
       SUM(oi.quantity * oi.price) AS total_sales,
       COUNT(DISTINCT ro.id) AS order_count,
       COUNT(DISTINCT ro.user_id) AS customer_count
FROM recent_orders ro
JOIN order_items oi ON oi.order_id = ro.id
JOIN products p ON oi.product_id = p.id
JOIN categories c ON p.category_id = c.id
GROUP BY c.name
ORDER BY total_sales DESC;

-- ステップ2: COUNT(DISTINCT) を避ける二段階集計（カテゴリ×注文 → カテゴリ）
EXPLAIN (ANALYZE, BUFFERS)
WITH per_order AS (
    SELECT p.category_id, o.id AS order_id, o.user_id,
           SUM(oi.quantity * oi.price) AS sales
    FROM orders o
    JOIN order_items oi ON oi.order_id = o.id
    JOIN products p ON oi.product_id = p.id
    WHERE o.ordered_at >= now() - interval '30 days'
      AND o.status NOT IN ('cancelled', 'returned')
    GROUP BY p.category_id, o.id, o.user_id
)
SELECT c.name AS category_name,
       SUM(po.sales) AS total_sales,
       count(*) AS order_count,
       COUNT(DISTINCT po.user_id) AS customer_count
FROM per_order po
JOIN categories c ON c.id = po.category_id
GROUP BY c.name
ORDER BY total_sales DESC;

-- ステップ3: 部分索引（取消・返品を除いた注文の期間）を試す。BEGIN 〜 ROLLBACK で残さない
-- （明細の order_id は一意制約 uq_order_items_order_product の索引ですでに引ける）
BEGIN;
CREATE INDEX idx_ch12_orders_recent
    ON orders (ordered_at DESC) INCLUDE (user_id)
    WHERE status NOT IN ('cancelled', 'returned');
EXPLAIN (ANALYZE, BUFFERS)
SELECT c.name AS category_name,
       SUM(oi.quantity * oi.price) AS total_sales,
       COUNT(DISTINCT o.id) AS order_count,
       COUNT(DISTINCT o.user_id) AS customer_count
FROM order_items oi
JOIN orders o ON oi.order_id = o.id
JOIN products p ON oi.product_id = p.id
JOIN categories c ON p.category_id = c.id
WHERE o.ordered_at >= now() - interval '30 days'
  AND o.status NOT IN ('cancelled', 'returned')
GROUP BY c.name
ORDER BY total_sales DESC;
SELECT pg_size_pretty(pg_relation_size('idx_ch12_orders_recent')) AS partial_size;
ROLLBACK;

-- ステップ4: work_mem を増やす（トランザクション限り）
BEGIN;
SET LOCAL work_mem = '128MB';
EXPLAIN (ANALYZE, BUFFERS)
SELECT c.name AS category_name,
       SUM(oi.quantity * oi.price) AS total_sales,
       COUNT(DISTINCT o.id) AS order_count,
       COUNT(DISTINCT o.user_id) AS customer_count
FROM order_items oi
JOIN orders o ON oi.order_id = o.id
JOIN products p ON oi.product_id = p.id
JOIN categories c ON p.category_id = c.id
WHERE o.ordered_at >= now() - interval '30 days'
  AND o.status NOT IN ('cancelled', 'returned')
GROUP BY c.name
ORDER BY total_sales DESC;
COMMIT;

-- ステップ5: マテビュー（直近30日のカテゴリ別。参照は速いが、REFRESH に元のSQLと同じ時間がかかる）
CREATE MATERIALIZED VIEW IF NOT EXISTS mv_ch12_category_sales_30d AS
SELECT c.id AS category_id,
       c.name AS category_name,
       SUM(oi.quantity * oi.price)::bigint AS total_sales,
       COUNT(DISTINCT o.id)::int AS order_count,
       COUNT(DISTINCT o.user_id)::int AS customer_count,
       now() AS refreshed_at
FROM order_items oi
JOIN orders o ON oi.order_id = o.id
JOIN products p ON oi.product_id = p.id
JOIN categories c ON p.category_id = c.id
WHERE o.ordered_at >= now() - interval '30 days'
  AND o.status NOT IN ('cancelled', 'returned')
GROUP BY c.id, c.name;
CREATE UNIQUE INDEX IF NOT EXISTS uq_mv_ch12_category_sales_30d
    ON mv_ch12_category_sales_30d (category_id);
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_ch12_category_sales_30d;
EXPLAIN (ANALYZE, BUFFERS)
SELECT category_name, total_sales, order_count, customer_count
FROM mv_ch12_category_sales_30d ORDER BY total_sales DESC;

-- ===== チューニングチェックリスト（付録E相当・抜粋） =====
-- □ EXPLAIN ANALYZEで実測したか □ 推定rowsと実測rowsの乖離はないか（→ANALYZE）
-- □ 先絞り（WHERE/CTE）しているか □ SELECT * をやめたか □ NOT IN をやめたか
-- □ 索引は効いているか（Seq Scanの理由: 選択率？統計？） □ work_memは足りているか（Sort/Hashの溢れ）
-- □ 書き込み影響（索引過多）を確認したか □ 改善前後を数値で記録したか
