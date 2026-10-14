-- 01_schema.sql — 作業スキーマの用意（第2章）
-- codes/sql-code/init/01_schema.sql@v1.2.2
-- 実行: psql -U sakura -d sakura_market -f init/01_schema.sql
--       （性能比較用の sakura_xl でも同じファイルを使う: -d sakura_xl）

CREATE SCHEMA IF NOT EXISTS sakura;

SET search_path TO sakura, public;

-- 以後の接続でも sakura が先に来るようにする。
-- :"DBNAME" は psql が「いま接続しているDB名」に置き換える（sakura_market / sakura_xl のどちらでも動く）
ALTER DATABASE :"DBNAME" SET search_path TO sakura, public;
