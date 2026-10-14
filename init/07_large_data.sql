-- 07_large_data.sql — 大規模データ: 行動ログ1000万行（第10〜14章の性能比較用 DB sakura_xl）
-- codes/sql-code/init/07_large_data.sql@v1.2.2
-- 前提: 06_medium_data.sql 投入済み。既定DB（sakura_market）ではなく sakura_xl に入れる:
--   make init-large DB=sakura_xl
-- 内容: behavior_logs を空にして、1000万行を「過去365日・時刻順」に作り直す。
--   ログは追記型なので、物理的な並びと created_at の順がそろうのが現実に近い（BRIN が効く。第10章）。
--   medium の100万行に足すと時刻順が2周になるため、作り直す。
-- 所要・容量（実測 v1.2.0。VALIDATION.md §2）: 約2分44秒。behavior_logs は表 882MB・索引込み 2,238MB。
-- 少なく試す: CALL sakura.gen_behavior_logs(1000000, 365);（=100万行）

SET search_path TO sakura, public;
SELECT setseed(0.44) \gset

TRUNCATE behavior_logs;
CALL sakura.gen_behavior_logs(10000000, 365, 1000000);

ANALYZE behavior_logs;
