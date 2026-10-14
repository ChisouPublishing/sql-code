-- 08_xlarge_data.sql — 超大規模データ1000万件級（第10〜14章の性能比較用 DB sakura_xl）
-- codes/sql-code/init/08_xlarge_data.sql@v1.2.2
-- 前提: 07_large_data.sql まで投入済みの sakura_xl:
--   make init-xlarge DB=sakura_xl   （= small → medium → large → xlarge を順に投入）
-- 到達規模: users 100万 / products 10万 / orders 1000万 / order_items 約3000万 /
--   状態履歴 約4000万 / payments・shipments 各 約1000万。
-- 所要・容量（実測 v1.2.0。VALIDATION.md §2）: 08 だけで約22分、small〜xlarge の合計で約25分・DB 22GB。
--   投入中にホストの空きが82GBから60GBに減った。df -h で空きを見る。
-- 方針:
--   * 注文は共通手続き sakura.gen_orders（04b_generators.sql）で作る。small・medium と同じ業務ルール
--     （状態履歴・決済・発送・返品・クーポン・送料・レビュー）
--   * 1回10万注文ずつ COMMIT。期間（過去730日）を99の区間に分け、古い区間から順に作る
--     （注文は時刻順に表へ追記される。実際の運用と同じ並び）
--   * 金額は明細から先に計算して INSERT する（後から1000万行を UPDATE すると表がほぼ倍に膨らむ）
--   * 途中で止めた場合: もう一度このファイルを流すと、1000万件に足りない分だけ作る
--     （ただし足した分は期間全体に散るので、時刻順の並びは少し崩れる）

SET search_path TO sakura, public;
SELECT setseed(0.45) \gset

-- 会員を100万人まで（user_xl_N、登録日は過去3年）
SELECT GREATEST(0, 1000000 - count(*))::int AS n_users FROM users \gset
CALL sakura.gen_users('user_xl_', 'ユーザーX', :n_users, 1095);

-- 商品を10万品まで（SKU-X-000001〜）と在庫
SELECT GREATEST(0, 100000 - count(*))::int AS n_products FROM products \gset
CALL sakura.gen_products('SKU-X-', '商品X', 6, :n_products);

ANALYZE users;
ANALYZE addresses;
ANALYZE products;
ANALYZE inventory;

-- 注文を1000万件まで（medium の10万件 + 990万件 = 99回 × 10万件）
SELECT GREATEST(0, 10000000 - count(*))::int AS n_orders FROM orders \gset
CALL sakura.gen_orders(:n_orders, 730, 5, 100000, 0.1, 0.12);

-- 統計情報（全表）
ANALYZE;
