-- ch07_llm_material.sql — 外部LLMへ渡す前に集計材料を確認する（第7章）
-- codes/sql-code/queries/ch07_llm_material.sql@v1.2.2
-- 教材の合成データ専用。結果を自動送信しない。
BEGIN READ ONLY;
SET LOCAL search_path TO sakura, public;
SELECT status, count(*) AS orders
FROM orders
GROUP BY status
HAVING count(*) >= 10
ORDER BY status;
ROLLBACK;
