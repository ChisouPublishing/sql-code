-- dashboard_bench.sql — pgbenchカスタム: ダッシュボード参照（第14章）
-- codes/sql-code/bench/dashboard_bench.sql@v1.2.2
-- 前提: queries/ch14_dashboard.sql 実行済み（マテビュー作成済み）。性能比較用DB sakura_xl で測る。
-- 実行: docker run --rm --network sql-code_default -e PGPASSWORD=sakura_dev -v "$PWD/bench:/bench:ro" postgres:18 \
--         pgbench -c 50 -j 8 -T 300 -f /bench/dashboard_bench.sql -U sakura -d sakura_xl -h sakura_market_db
-- P95/P99: pgbench --log --log-prefix=/tmp/... で取得し集計する（第13章 §13.6）。
SELECT category_name, total_sales, order_count, customer_count, prev_sales, growth_pct, today_refreshed_at
FROM sakura.mv_category_sales_dashboard ORDER BY total_sales DESC;
