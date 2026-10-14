-- ch11_monitoring.sql — スロークエリログと監視（第11章）
-- codes/sql-code/queries/ch11_monitoring.sql@v1.2.2
-- 前提: docker-compose.yml（shared_preload_libraries=pg_stat_statements、slow-log 200ms）。
--       どちらのDBでも動く。遅いクエリを集めるなら sakura_xl で第10・12章のクエリを流したあとがよい。

SET search_path TO sakura, public;

-- ===== 設定の確認 =====
SHOW log_min_duration_statement;  -- 200 期待
SHOW shared_preload_libraries;    -- pg_stat_statements 含む期待

-- 変更する場合の注意: 本書のcomposeは log_min_duration_statement と
-- log_line_prefix を起動引数（-c）で固定している。起動引数は ALTER SYSTEM より
-- 優先されるため、値の変更は docker-compose.yml の編集＋
-- docker compose up -d（再起動）で行う。
-- （ALTER SYSTEM SET ... + pg_reload_conf では変わらないことを実測で確認）

-- ===== pg_stat_statements 有効化 =====
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- 以下の4つの分析は、接続中のDBに絞る（pg_stat_statements はサーバー全体の統計で、
-- 同じサーバーの別のDBの行も混ざる。サーバー全体を見るときは dbid の行を外す）

-- 合計時間順 TOP20
SELECT queryid, calls,
       round(total_exec_time::numeric, 2) AS total_ms,
       round(mean_exec_time::numeric, 2) AS mean_ms,
       rows, left(query, 120) AS query
FROM pg_stat_statements
WHERE query NOT LIKE '%pg_stat_statements%'
  AND dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
ORDER BY total_exec_time DESC LIMIT 20;

-- 平均時間順（10回以上実行）
SELECT queryid, calls,
       round(mean_exec_time::numeric, 2) AS mean_ms,
       round(max_exec_time::numeric, 2) AS max_ms,
       left(query, 120) AS query
FROM pg_stat_statements
WHERE query NOT LIKE '%pg_stat_statements%' AND calls >= 10
  AND dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
ORDER BY mean_exec_time DESC LIMIT 20;

-- 呼び出し回数順
SELECT queryid, calls,
       round(mean_exec_time::numeric, 2) AS mean_ms,
       left(query, 120) AS query
FROM pg_stat_statements
WHERE query NOT LIKE '%pg_stat_statements%'
  AND dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
ORDER BY calls DESC LIMIT 20;

-- I/O負荷順（読みが多いクエリ）
SELECT queryid, calls, shared_blks_read,
       round(100.0 * shared_blks_read / NULLIF(shared_blks_read + shared_blks_hit, 0), 2) AS read_ratio_pct,
       left(query, 120) AS query
FROM pg_stat_statements
WHERE query NOT LIKE '%pg_stat_statements%'
  AND dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
ORDER BY shared_blks_read DESC LIMIT 20;

-- リセット（計測し直すとき）
-- SELECT pg_stat_statements_reset();

-- ===== スナップショット表（定期蓄積→差分集計） =====
CREATE TABLE IF NOT EXISTS pgss_snapshots (
    snapshot_at timestamptz NOT NULL DEFAULT now(),
    queryid bigint NOT NULL,
    query text NOT NULL,
    calls bigint NOT NULL,
    total_exec_time double precision NOT NULL,
    mean_exec_time double precision NOT NULL,
    rows bigint NOT NULL
);

INSERT INTO pgss_snapshots (queryid, query, calls, total_exec_time, mean_exec_time, rows)
SELECT queryid, query, calls, total_exec_time, mean_exec_time, rows
FROM pg_stat_statements
WHERE query NOT LIKE '%pg_stat_statements%';

-- pg_cron が使える環境では定期化（stock imageに無ければスキップ）
DO
$do$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_cron') THEN
        CREATE EXTENSION IF NOT EXISTS pg_cron;
        PERFORM cron.schedule('pgss-snapshot', '0 * * * *',
            $$INSERT INTO sakura.pgss_snapshots (queryid, query, calls, total_exec_time, mean_exec_time, rows)
              SELECT queryid, query, calls, total_exec_time, mean_exec_time, rows
              FROM pg_stat_statements WHERE query NOT LIKE '%pg_stat_statements%'$$);
        PERFORM cron.schedule('pgss-cleanup', '0 3 * * *',
            $$DELETE FROM sakura.pgss_snapshots WHERE snapshot_at < now() - interval '30 days'$$);
    ELSE
        RAISE NOTICE 'pg_cron not available; snapshot manually';
    END IF;
END;
$do$;

-- ===== 日次監視クエリ =====
-- 1秒超の平均クエリ件数
SELECT count(*) AS slow_queries FROM pg_stat_statements WHERE mean_exec_time > 1000;
-- 未使用索引
SELECT relname, indexrelname FROM pg_stat_user_indexes
WHERE schemaname = 'sakura' AND idx_scan = 0 ORDER BY 1, 2;
-- テーブル容量
SELECT relname, pg_size_pretty(pg_total_relation_size(relid)) AS size
FROM pg_stat_user_tables WHERE schemaname = 'sakura'
ORDER BY pg_total_relation_size(relid) DESC;
-- キャッシュヒット率
SELECT relname,
       round(100.0 * heap_blks_hit / NULLIF(heap_blks_hit + heap_blks_read, 0), 2) AS hit_pct
FROM pg_statio_user_tables WHERE schemaname = 'sakura' ORDER BY relname;

-- ===== pgBadger（ログの可視化。第11章 §08、CHANGELOG v1.1.1） =====
-- composeのログは各行の先頭に「sakura_market_db  | 」が付く。pgBadger はこれを読めないので、
-- sed で取り除いてから渡す。さらに --prefix に log_line_prefix（compose の -c と同じ文字列）を渡す。
--   docker compose logs postgres > /tmp/postgresql.log
--   sed 's/^[^|]*| //' /tmp/postgresql.log > /tmp/pg.clean.log
--   pgbadger --prefix '%m [%p] %q%u@%d ' /tmp/pg.clean.log -o /tmp/pgbadger.html
