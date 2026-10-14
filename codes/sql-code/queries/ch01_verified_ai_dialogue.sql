-- ch01_verified_ai_dialogue.sql — 実応答と改善後の照合（第1章）
-- codes/sql-code/queries/ch01_verified_ai_dialogue.sql@v1.2.2
-- 証跡: evidence/20261012_ai_response_verification/
-- AI応答の注意書きは本文・証跡で確認すること。
BEGIN READ ONLY;
SET LOCAL search_path TO sakura, public;
SET LOCAL statement_timeout TO '5s';
-- 試行04/06で観測したSELECT（業務上の顧客名はdisplay_name）
SELECT email AS customer_name
FROM users
WHERE rank = 'gold'
LIMIT 5;
-- 試行05で観測した改善後のSELECT
SELECT display_name AS customer_name
FROM users
WHERE rank = 'gold'
  AND deleted_at IS NULL
ORDER BY id ASC
LIMIT 5;
-- 人間が用意した基準SQL
SELECT display_name AS customer_name
FROM sakura.users
WHERE rank = 'gold'
  AND deleted_at IS NULL
ORDER BY id
LIMIT 5;
ROLLBACK;
