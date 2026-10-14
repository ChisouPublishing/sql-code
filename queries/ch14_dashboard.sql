-- ch14_dashboard.sql — 総合実戦: リアルタイム売上ダッシュボード（第14章）
-- codes/sql-code/queries/ch14_dashboard.sql@v1.2.2
-- 要件: カテゴリ別売上・注文数・顧客数・前期比・更新時刻 / 5分以内更新 /
-- 100回/分アクセス / 直近30日対象 / 応答100ms以内。
-- 口径: 売上=SUM(qty*price)税込（値引き前・送料を含まない）、cancelled/returned除外、ordered_at基準、
--       日付はJST。直近30日 = 今日を含む30日（昨日までの29日＋今日）、前期 = その前の30日。
-- 前提: 性能比較用DB sakura_xl（orders 1000万）。既定DB sakura_market でも動く。
-- 何度流してもよい（表は IF NOT EXISTS、集計は UPSERT、マテビューは最後に REFRESH）。

SET search_path TO sakura, public;

-- ===== 層1: 集計表（日次＋当日） =====
CREATE TABLE IF NOT EXISTS daily_category_sales (
    category_id uuid NOT NULL REFERENCES categories (id),
    sale_date date NOT NULL,                 -- JSTの日付
    total_sales bigint NOT NULL DEFAULT 0,
    order_count int NOT NULL DEFAULT 0,
    customer_count int NOT NULL DEFAULT 0,   -- その日の顧客数（日をまたいで足すと延べ人数になる）
    refreshed_at timestamptz NOT NULL DEFAULT now(),   -- この行を集計した時刻
    PRIMARY KEY (category_id, sale_date)
);
CREATE INDEX IF NOT EXISTS idx_daily_category_sales_date
    ON daily_category_sales (sale_date DESC, category_id);

CREATE TABLE IF NOT EXISTS today_category_sales (
    category_id uuid NOT NULL PRIMARY KEY REFERENCES categories (id),
    total_sales bigint NOT NULL DEFAULT 0,
    order_count int NOT NULL DEFAULT 0,
    customer_count int NOT NULL DEFAULT 0,
    refreshed_at timestamptz NOT NULL DEFAULT now()
);

-- ===== リフレッシュ①: バックフィル（運用開始時に1回。前期比に要る過去61日分） =====
-- 期間は ordered_at の範囲条件で書く（列を関数で包まない → 索引 idx_orders_ordered_at が使える）
INSERT INTO daily_category_sales (category_id, sale_date, total_sales, order_count, customer_count)
SELECT p.category_id, (o.ordered_at AT TIME ZONE 'Asia/Tokyo')::date AS sale_date,
       SUM(oi.quantity * oi.price)::bigint,
       count(DISTINCT o.id)::int,
       count(DISTINCT o.user_id)::int
FROM orders o
JOIN order_items oi ON oi.order_id = o.id
JOIN products p ON oi.product_id = p.id
WHERE o.status NOT IN ('cancelled', 'returned')
  AND o.ordered_at >= (((now() AT TIME ZONE 'Asia/Tokyo')::date - 61)::timestamp AT TIME ZONE 'Asia/Tokyo')
  AND o.ordered_at <  (((now() AT TIME ZONE 'Asia/Tokyo')::date)::timestamp AT TIME ZONE 'Asia/Tokyo')
GROUP BY p.category_id, sale_date
ON CONFLICT (category_id, sale_date) DO UPDATE SET
    total_sales = EXCLUDED.total_sales,
    order_count = EXCLUDED.order_count,
    customer_count = EXCLUDED.customer_count,
    refreshed_at = now();

-- ===== リフレッシュ②: 前日分のUPSERT（毎日1回、0時過ぎ） =====
-- 返品・取消で前日の数字が後から変わる業務なら、範囲を「数日前から」に広げて入れ直す
INSERT INTO daily_category_sales (category_id, sale_date, total_sales, order_count, customer_count)
SELECT p.category_id, (o.ordered_at AT TIME ZONE 'Asia/Tokyo')::date AS sale_date,
       SUM(oi.quantity * oi.price)::bigint,
       count(DISTINCT o.id)::int,
       count(DISTINCT o.user_id)::int
FROM orders o
JOIN order_items oi ON oi.order_id = o.id
JOIN products p ON oi.product_id = p.id
WHERE o.status NOT IN ('cancelled', 'returned')
  AND o.ordered_at >= (((now() AT TIME ZONE 'Asia/Tokyo')::date - 1)::timestamp AT TIME ZONE 'Asia/Tokyo')
  AND o.ordered_at <  (((now() AT TIME ZONE 'Asia/Tokyo')::date)::timestamp AT TIME ZONE 'Asia/Tokyo')
GROUP BY p.category_id, sale_date
ON CONFLICT (category_id, sale_date) DO UPDATE SET
    total_sales = EXCLUDED.total_sales,
    order_count = EXCLUDED.order_count,
    customer_count = EXCLUDED.customer_count,
    refreshed_at = now();

-- ===== リフレッシュ③: 当日分（5分ごと。作り直し） =====
-- カテゴリを起点に LEFT JOIN し、注文の無いカテゴリも0で入れる（表を空にしない → 鮮度を監視できる）。
-- 1トランザクションで入れ替えるので、読み手には古い当日分か新しい当日分のどちらかが見える
BEGIN;
TRUNCATE today_category_sales;
INSERT INTO today_category_sales (category_id, total_sales, order_count, customer_count)
SELECT c.id,
       COALESCE(t.total_sales, 0),
       COALESCE(t.order_count, 0),
       COALESCE(t.customer_count, 0)
FROM categories c
LEFT JOIN (
    SELECT p.category_id,
           SUM(oi.quantity * oi.price)::bigint AS total_sales,
           count(DISTINCT o.id)::int AS order_count,
           count(DISTINCT o.user_id)::int AS customer_count
    FROM orders o
    JOIN order_items oi ON oi.order_id = o.id
    JOIN products p ON oi.product_id = p.id
    WHERE o.status NOT IN ('cancelled', 'returned')
      AND o.ordered_at >= (((now() AT TIME ZONE 'Asia/Tokyo')::date)::timestamp AT TIME ZONE 'Asia/Tokyo')
    GROUP BY p.category_id
) t ON t.category_id = c.id;
COMMIT;

-- ===== 層2: 参照VIEW（直近30日＋前期＋成長率） =====
-- 売上・注文数は日ごとに足してよい（1つの注文は1日にしか属さない）。
-- 顧客数は足せない（同じ人が2日買うと2人になる）ので、期間で重複を除いて元データから数える。
-- 元データを読むぶん VIEW は重い → 画面は層3のマテビューを読む。
-- 鮮度の列は層ごとに分ける（どちらも集計表を作った時刻。参照した時刻 now() ではない）:
--   daily_refreshed_at = 日次集計（今期の範囲）の最新の集計時刻。リフレッシュ②で毎日進む
--   today_refreshed_at = 当日集計の集計時刻。リフレッシュ③で5分ごとに進む。画面に出す更新時刻
-- v1.2.0 の VIEW（鮮度の列が refreshed_at の1列）が残っていれば、マテビューごと消して作り直す
-- （列の名前は CREATE OR REPLACE VIEW では変えられない。新しく作ったDBでは何もしない）
DO
$do$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema = 'sakura' AND table_name = 'v_category_sales_dashboard'
                 AND column_name = 'refreshed_at') THEN
        DROP MATERIALIZED VIEW IF EXISTS sakura.mv_category_sales_dashboard;
        DROP VIEW sakura.v_category_sales_dashboard;
    END IF;
END;
$do$;
CREATE OR REPLACE VIEW v_category_sales_dashboard AS
WITH bounds AS (
    SELECT (now() AT TIME ZONE 'Asia/Tokyo')::date AS today
),
cur AS (
    SELECT d.category_id,
           SUM(d.total_sales)::bigint AS sales,
           SUM(d.order_count)::int AS orders,
           MAX(d.refreshed_at) AS daily_refreshed_at
    FROM daily_category_sales d CROSS JOIN bounds b
    WHERE d.sale_date >= b.today - 29 AND d.sale_date < b.today
    GROUP BY d.category_id
),
prev AS (
    SELECT d.category_id, SUM(d.total_sales)::bigint AS sales
    FROM daily_category_sales d CROSS JOIN bounds b
    WHERE d.sale_date >= b.today - 59 AND d.sale_date < b.today - 29
    GROUP BY d.category_id
),
customers AS (
    SELECT p.category_id, count(DISTINCT o.user_id)::int AS customers
    FROM orders o
    JOIN order_items oi ON oi.order_id = o.id
    JOIN products p ON oi.product_id = p.id
    CROSS JOIN bounds b
    WHERE o.status NOT IN ('cancelled', 'returned')
      AND o.ordered_at >= ((b.today - 29)::timestamp AT TIME ZONE 'Asia/Tokyo')
    GROUP BY p.category_id
)
SELECT c.id AS category_id,
       c.name AS category_name,
       COALESCE(cur.sales, 0) + COALESCE(t.total_sales, 0) AS total_sales,
       COALESCE(cur.orders, 0) + COALESCE(t.order_count, 0) AS order_count,
       COALESCE(cu.customers, 0) AS customer_count,
       COALESCE(prev.sales, 0) AS prev_sales,
       round(100.0 * ((COALESCE(cur.sales, 0) + COALESCE(t.total_sales, 0)) - prev.sales)
             / NULLIF(prev.sales, 0), 2) AS growth_pct,
       cur.daily_refreshed_at,                    -- 日次集計の最新の集計時刻
       t.refreshed_at AS today_refreshed_at       -- 当日集計の集計時刻（画面の「更新時刻」）
FROM categories c
LEFT JOIN cur ON cur.category_id = c.id
LEFT JOIN prev ON prev.category_id = c.id
LEFT JOIN today_category_sales t ON t.category_id = c.id
LEFT JOIN customers cu ON cu.category_id = c.id;

-- ===== 層3: マテビュー（画面はここを読む。100ms以内） =====
-- 一意索引は category_id（カテゴリ名は親が違えば重複しうる）。CONCURRENTLY の更新に必須
CREATE MATERIALIZED VIEW IF NOT EXISTS mv_category_sales_dashboard AS
SELECT * FROM v_category_sales_dashboard;
CREATE UNIQUE INDEX IF NOT EXISTS uq_mv_dashboard
    ON mv_category_sales_dashboard (category_id);
-- 再実行したときも最新にする（CREATE ... IF NOT EXISTS は既存のマテビューを更新しない）。
-- 更新の順序は 層1（①〜③）→ 層3
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_category_sales_dashboard;

-- ダッシュボード参照
EXPLAIN (ANALYZE, BUFFERS)
SELECT category_name, total_sales, order_count, customer_count, prev_sales, growth_pct, today_refreshed_at
FROM mv_category_sales_dashboard ORDER BY total_sales DESC;
SELECT category_name, total_sales, order_count, customer_count, prev_sales, growth_pct, today_refreshed_at
FROM mv_category_sales_dashboard ORDER BY total_sales DESC;

-- ===== 運用（pg_cronがあれば定期化） =====
DO
$do$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_cron') THEN
        CREATE EXTENSION IF NOT EXISTS pg_cron;
        PERFORM cron.schedule('dash-daily', '5 0 * * *',
            $$SELECT 1$$);  -- 実運用では リフレッシュ② を登録
        PERFORM cron.schedule('dash-today', '*/5 * * * *',
            $$SELECT 1$$);  -- 実運用では リフレッシュ③ と REFRESH MATERIALIZED VIEW CONCURRENTLY を登録
    ELSE
        RAISE NOTICE 'pg_cron not available; refresh manually';
    END IF;
END;
$do$;

-- ===== 監視（鮮度・スロー） =====
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
SELECT MAX(refreshed_at) AS daily_last_refresh FROM daily_category_sales;
SELECT queryid, calls, round(mean_exec_time::numeric, 2) AS mean_ms
FROM pg_stat_statements
WHERE query LIKE '%mv_category_sales_dashboard%'
ORDER BY mean_exec_time DESC LIMIT 10;
-- 鮮度アラート（当日分が10分更新されていない、または空なら警告）
DO
$do$
DECLARE
    last_refresh timestamptz;
BEGIN
    SELECT MAX(refreshed_at) INTO last_refresh FROM sakura.today_category_sales;
    IF last_refresh IS NULL OR last_refresh < now() - interval '10 minutes' THEN
        RAISE WARNING 'today_category_sales is stale: last_refresh=%', last_refresh;
    ELSE
        RAISE NOTICE 'today_category_sales is fresh: last_refresh=%', last_refresh;
    END IF;
END;
$do$;

-- ===== 負荷テスト（第13章の手順で） =====
-- docker run --rm --network sql-code_default -e PGPASSWORD=sakura_dev -v "$PWD/bench:/bench:ro" postgres:18 \
--   pgbench -c 50 -j 8 -T 300 -f /bench/dashboard_bench.sql -U sakura -d sakura_xl -h sakura_market_db
-- 実測は VALIDATION.md（環境で変わる）
