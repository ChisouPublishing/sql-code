-- ch08_verify.sql — 試し実行（試運行）4段階・検証・防御・権限（第8章）
-- codes/sql-code/queries/ch08_verify.sql@v1.2.2
-- 段階を追って実行すること。§8.4の書込みはすべてROLLBACKする。
-- 前提: 既定DB sakura_market（small＋medium）。権限の節もROLLBACKで終わり、ロールをDBに残さない。
SET search_path TO sakura, public;

-- ===== ① 構文チェック（実行しない） =====
EXPLAIN
SELECT u.display_name, count(o.id) AS orders
FROM users u LEFT JOIN orders o ON o.user_id = u.id
GROUP BY u.display_name;

-- ===== ② 小データ（LIMIT 100） =====
SELECT o.id, o.status, o.amount, o.ordered_at
FROM orders o ORDER BY o.ordered_at DESC LIMIT 100;

-- ===== ③ 境界値 =====
-- NULL: クーポン未使用の注文はあるか
SELECT count(*) AS no_coupon FROM orders WHERE coupon_id IS NULL;
-- 0件: 存在しないランク
SELECT count(*) AS zero_case FROM users WHERE rank = 'diamond';
-- 最大/最小: 注文金額の両端
SELECT MIN(amount) AS min_amount, MAX(amount) AS max_amount FROM orders;
-- 重複: 同一ユーザーの同一商品レビューはUNIQUEで防がれているか
SELECT user_id, product_id, count(*) FROM reviews
GROUP BY user_id, product_id HAVING count(*) > 1;

-- ===== 件数照合（全数−注文者＝未注文者） =====
SELECT (SELECT count(*) FROM users) AS all_users,
       (SELECT count(DISTINCT user_id) FROM orders) AS ordered_users,
       (SELECT count(*) FROM users u WHERE NOT EXISTS (
           SELECT 1 FROM orders o WHERE o.user_id = u.id)) AS never_ordered;

-- ===== データ整合性チェック（すべて0件期待） =====
-- 外部キー
SELECT count(*) AS orphan_items FROM order_items oi
LEFT JOIN orders o ON oi.order_id = o.id WHERE o.id IS NULL;
-- 日付論理
SELECT count(*) AS bad_dates FROM shipments s
JOIN orders o ON s.order_id = o.id
WHERE s.shipped_at < o.ordered_at;
-- 業務ルール
SELECT count(*) AS negative_stock FROM inventory WHERE stock < 0;
-- 金額の照合（v1.2.0〜）: 決済額 = 注文の請求額、請求額 = 小計 - 値引き + 送料
SELECT count(*) AS payment_mismatch FROM payments p
JOIN orders o ON o.id = p.order_id WHERE p.amount <> o.amount;
SELECT count(*) AS breakdown_mismatch FROM orders
WHERE amount <> subtotal - discount_amount + shipping_fee;

-- 状態履歴から「いつキャンセルされたか」を引く（orders.status は今の状態しか持たない）
SELECT o.id, o.ordered_at, h.changed_at AS cancelled_at, h.from_status, h.note
FROM orders o
JOIN order_status_histories h ON h.order_id = o.id AND h.to_status = 'cancelled'
ORDER BY h.changed_at DESC
LIMIT 5;

-- ===== ④ 全量はトランザクションで包む =====
BEGIN;
UPDATE products SET price = price * 1.1 WHERE sku = 'SKU-0001';
SELECT sku, price FROM products WHERE sku = 'SKU-0001';
ROLLBACK;

-- セーブポイントの使い方
BEGIN;
UPDATE coupons SET used_count = used_count + 1 WHERE code = 'CPN0001';
SAVEPOINT sp1;
UPDATE coupons SET used_count = 999999 WHERE code = 'CPN0001';
ROLLBACK TO SAVEPOINT sp1;
SELECT code, used_count FROM coupons WHERE code = 'CPN0001';
ROLLBACK;

-- ===== 権限分離（読み取り専用ユーザー） =====
-- ロールはDBクラスタ全体で共有される。共用の開発DBに試しのロールを残さないよう、
-- この節は BEGIN 〜 ROLLBACK で包む（CREATE ROLE も GRANT もトランザクションで取り消せる）。
-- 本当に作るときは ROLLBACK を COMMIT に変え、使い終わったら末尾の後片付けを実行する。
BEGIN;
CREATE ROLE app_readonly WITH LOGIN PASSWORD 'readonly_dev';
CREATE ROLE app_readwrite WITH LOGIN PASSWORD 'readwrite_dev';

GRANT USAGE ON SCHEMA sakura TO app_readonly;
-- 注意: ON ALL TABLES は「表」だけでなく、ビュー・マテビューにも権限を付ける
GRANT SELECT ON ALL TABLES IN SCHEMA sakura TO app_readonly;
-- これから作る表にも自動で SELECT を付ける（作成者＝このSQLを流したロールの表が対象）
ALTER DEFAULT PRIVILEGES IN SCHEMA sakura GRANT SELECT ON TABLES TO app_readonly;

GRANT USAGE ON SCHEMA sakura TO app_readwrite;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA sakura TO app_readwrite;
ALTER DEFAULT PRIVILEGES IN SCHEMA sakura
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO app_readwrite;

-- 権限の確認
SELECT grantee, table_name, string_agg(privilege_type, ',' ORDER BY privilege_type) AS privileges
FROM information_schema.table_privileges
WHERE grantee IN ('app_readonly', 'app_readwrite') AND table_schema = 'sakura'
GROUP BY grantee, table_name
ORDER BY grantee, table_name
LIMIT 20;

-- 読み取り専用ロールで書き込めないことを確かめる（SET ROLE はこのトランザクションの中だけ）
SET LOCAL ROLE app_readonly;
SELECT count(*) AS readable_orders FROM orders;
SAVEPOINT before_write;
-- 次の UPDATE は「permission denied for table products」で失敗するのが正しい
DO
$do$
BEGIN
    UPDATE sakura.products SET price = price WHERE sku = 'SKU-0001';
    RAISE NOTICE 'NG: app_readonly で更新できてしまった';
EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'OK: app_readonly は更新できない（%）', SQLERRM;
END;
$do$;
RESET ROLE;
ROLLBACK;   -- ロール・権限・既定権限をすべて取り消す

-- 後片付け（COMMIT で本当に作った場合だけ）: 権限と既定権限を外してから、ロールを消す。
-- DROP OWNED BY は「このDBの中」の権限・既定権限・所有物を消す（DBごとに実行）。
-- DROP ROLE はそのあとでないと「依存するオブジェクトがある」で失敗する。
-- DROP OWNED BY app_readonly, app_readwrite;
-- DROP ROLE app_readonly;
-- DROP ROLE app_readwrite;
