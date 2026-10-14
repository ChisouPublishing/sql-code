-- 06_medium_data.sql — 中規模データ10万行級（第4〜9章・第15章の既定DB sakura_market）
-- codes/sql-code/init/06_medium_data.sql@v1.2.2
-- 前提: 05_small_data.sql 投入済み（small に足す）。
-- 到達規模: users 10万 / products 1万 / orders 10万 / order_items 約30万（明細1〜5行、平均3行）/
--   状態履歴 約40万 / behavior_logs 約100万（過去365日、時刻順）。
-- 所要（実測 v1.2.0、OrbStack・M系Mac。VALIDATION.md §1・§2）: 約22秒（make init-medium 全体で約24秒）。
-- v1.1.1 までの不具合: 商品の category_id / seller_id を無相関の副問合せ
--   (SELECT id FROM categories ORDER BY random() LIMIT 1) で割っていたため、
--   InitPlan として1回しか評価されず、追加の9900品がすべて同じカテゴリ・販売者になっていた。
--   v1.2.0 では共通手続き（配列インデックス方式）に置き換えた。
-- 業務ルールは 04b_generators.sql の冒頭を参照。

SET search_path TO sakura, public;
SELECT setseed(0.43) \gset

-- 会員 +99,900人（登録日は過去3年。注文期間の2年より前から会員がいる）
CALL sakura.gen_users('user_medium_', 'ユーザーM', 99900, 1095);

-- 商品 +9,900品（SKU-M-00001〜）と在庫
CALL sakura.gen_products('SKU-M-', '商品M', 5, 9900);

-- 注文 +99,950件（過去730日、明細1〜5行）。small の50件と合わせて10万件
CALL sakura.gen_orders(99950, 730, 5);

-- 行動ログ +100万行（過去365日、時刻順に追記）
CALL sakura.gen_behavior_logs(1000000, 365);

-- 統計情報（EXPLAIN の推定精度のため全表。categories など小さい表も含む）
ANALYZE;
