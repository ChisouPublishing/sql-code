-- ch05_csv_roundtrip.sql — CSVを取り込み、型と往復結果を検証する（第5章）
-- codes/sql-code/queries/ch05_csv_roundtrip.sql@v1.2.2
-- input.csvをコンテナの/tmp/ai-sql-csv-input.csvへコピーしてから実行する。
-- 一時表だけを使い、既存の業務データは変更しない。
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL DateStyle TO 'ISO, YMD';
SET LOCAL TIME ZONE 'Asia/Tokyo';

-- ① 最初は全列を文字列として受け取る。
CREATE TEMP TABLE csv_stage (
    item_code text,
    label text,
    observed_on text,
    amount text,
    memo text
) ON COMMIT DROP;
\copy csv_stage FROM '/tmp/ai-sql-csv-input.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8', NULL '\N')

-- ② 表記を検査してから型を付ける。invalid_rowsは0を確認する。
SELECT count(*) AS imported_rows FROM csv_stage;
SELECT count(*) AS invalid_rows
FROM csv_stage
WHERE item_code IS NULL OR item_code !~ '^[0-9]{5}$'
   OR label IS NULL OR label = ''
   OR observed_on IS NULL OR observed_on !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
   OR amount IS NULL OR amount !~ '^[0-9]+$';

-- 表記が違うまま次へ進めない。日付の実在性は続くキャストでも確認する。
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM csv_stage
        WHERE item_code IS NULL OR item_code !~ '^[0-9]{5}$'
           OR label IS NULL OR label = ''
           OR observed_on IS NULL OR observed_on !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
           OR amount IS NULL OR amount !~ '^[0-9]+$'
    ) THEN
        RAISE EXCEPTION 'CSVの表記を確認してください';
    END IF;
END;
$$;

-- 日付へのキャストは、2026-02-30など存在しない日付も拒否する。
CREATE TEMP TABLE csv_typed ON COMMIT DROP AS
SELECT item_code, label, observed_on::date AS observed_on,
       amount::integer AS amount, memo
FROM csv_stage;
SELECT item_code, observed_on, amount,
       memo IS NULL AS memo_is_null,
       memo = '' AS memo_is_empty
FROM csv_typed
ORDER BY item_code;

-- ③ 列の順序と並び順を指定して書き出す。
\copy (SELECT item_code, label, observed_on, amount, memo FROM csv_typed ORDER BY item_code) TO '/tmp/ai-sql-csv-output.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8', NULL '\N')

-- ④ 書き出したCSVを読み戻し、重複を含めて両方向の差分を調べる。
CREATE TEMP TABLE csv_reloaded (LIKE csv_typed) ON COMMIT DROP;
\copy csv_reloaded FROM '/tmp/ai-sql-csv-output.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8', NULL '\N')
SELECT count(*) AS roundtrip_diff
FROM (
    (SELECT * FROM csv_typed EXCEPT ALL SELECT * FROM csv_reloaded)
    UNION ALL
    (SELECT * FROM csv_reloaded EXCEPT ALL SELECT * FROM csv_typed)
) AS differences;
ROLLBACK;
