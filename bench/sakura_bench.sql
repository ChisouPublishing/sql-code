-- sakura_bench.sql — pgbenchカスタム: 購買フロー（読み取りのみ。第13章 §13.5）
-- codes/sql-code/bench/sakura_bench.sql@v1.2.2
-- 1トランザクション = 会員1人が「ログイン → 商品を見る → 同じカテゴリの商品を探す → 注文履歴を見る」。
-- どの参照も一意索引・外部キーの索引で数行だけを引く（実際の画面と同じ引き方）。
-- 会員・商品は medium の番号（user_medium_1〜99900、SKU-M-00001〜09900）から選ぶ。
-- sakura_market・sakura_xl のどちらにもある（small だけのDBでは0行が返るが、SQLはエラーにならない）。
-- 実行（コンテナのpgbench）:
--   docker run --rm --network sql-code_default -e PGPASSWORD=sakura_dev -v "$PWD/bench:/bench:ro" postgres:18 \
--     pgbench -c 10 -j 2 -T 60 -f /bench/sakura_bench.sql -U sakura -d sakura_xl -h sakura_market_db
-- デバッグ: pgbench -c 1 -j 1 -t 1 -f /bench/sakura_bench.sql ...
\set user_no random(1, 99900)
\set product_no random(1, 9900)

-- ログイン相当: メールアドレス（一意索引）で会員を引く
SELECT id, rank FROM sakura.users
WHERE email = 'user_medium_' || :user_no || '@example.com';
-- 商品詳細: SKU（一意索引）で商品と在庫を引く
SELECT p.id, p.name_ja, p.price, i.stock
FROM sakura.products p JOIN sakura.inventory i ON i.product_id = p.id
WHERE p.sku = 'SKU-M-' || lpad(:product_no::text, 5, '0');
-- 商品検索: 同じカテゴリの商品を価格の安い順に5件
SELECT id, name_ja, price FROM sakura.products
WHERE category_id = (SELECT category_id FROM sakura.products
                     WHERE sku = 'SKU-M-' || lpad(:product_no::text, 5, '0'))
  AND deleted_at IS NULL
ORDER BY price LIMIT 5;
-- 注文履歴: その会員の新しい注文10件
SELECT o.id, o.status, o.amount, o.ordered_at
FROM sakura.orders o
WHERE o.user_id = (SELECT id FROM sakura.users WHERE email = 'user_medium_' || :user_no || '@example.com')
ORDER BY o.ordered_at DESC LIMIT 10;
