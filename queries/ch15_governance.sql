-- ch15_governance.sql — ガバナンス・権限・監査（第15章 §15.3）
-- codes/sql-code/queries/ch15_governance.sql@v1.2.2
-- 前提: 既定DB sakura_market。通常の postgres:18 で実行可（vector不要）。
-- このファイル全体を BEGIN 〜 ROLLBACK で包み、ロール・権限・RLS・トリガー・監査表をDBに残さない。
-- 本当に適用するときは、最後の ROLLBACK を COMMIT に変える（ロールはDBクラスタ全体に効く点に注意）。

SET search_path TO sakura, public;

BEGIN;

-- ===== ロールと権限 =====
CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE ROLE analyst WITH LOGIN PASSWORD 'analyst_dev';      -- 分析担当（読むだけ）
CREATE ROLE developer WITH LOGIN PASSWORD 'developer_dev';  -- 開発者（読み書き）

GRANT USAGE ON SCHEMA sakura TO analyst, developer;
GRANT SELECT ON ALL TABLES IN SCHEMA sakura TO analyst;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA sakura TO developer;

-- 列の制限（analyst からメールアドレスを隠す）
-- 誤り: REVOKE SELECT (email) ON users FROM analyst;
--   → 表全体の SELECT 権限が残っているので、email も読めてしまう（列の REVOKE は表の権限を削らない）
-- 正: 表の SELECT を外してから、見せてよい列だけを列単位で GRANT する
REVOKE SELECT ON users FROM analyst;
GRANT SELECT (id, display_name, rank, created_at, updated_at, deleted_at) ON users TO analyst;

-- 確認: analyst が users のどの列を読めるか
SELECT column_name, privilege_type
FROM information_schema.column_privileges
WHERE grantee = 'analyst' AND table_schema = 'sakura' AND table_name = 'users'
ORDER BY column_name;

-- 実際に試す（SET LOCAL ROLE はこのトランザクションの中だけ）
SET LOCAL ROLE analyst;
SELECT id, display_name, rank FROM users LIMIT 1;   -- 読める
SAVEPOINT try_email;
DO
$do$
BEGIN
    PERFORM email FROM sakura.users LIMIT 1;
    RAISE NOTICE 'NG: analyst が email を読めてしまった';
EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'OK: analyst は email を読めない（%）', SQLERRM;
END;
$do$;
RESET ROLE;

-- ===== 行レベルセキュリティ（RLS） =====
-- analyst には「アプリが設定した会員（app.current_user_id）」の注文だけを見せる。
-- current_setting(..., true) は未設定なら NULL、RESET 後は空文字 '' を返すことがある。
-- ''::uuid はエラーになるので、NULLIF で空文字を NULL にしてから型を変える（NULL なら0行）
ALTER TABLE orders ENABLE ROW LEVEL SECURITY;
CREATE POLICY p_orders_self ON orders
    FOR SELECT TO analyst
    USING (user_id = NULLIF(current_setting('app.current_user_id', true), '')::uuid);

-- 明細も同じ会員の注文の分だけにする（orders だけに RLS を掛けると、明細は全件見えてしまう）。
-- 副問合せの orders にも analyst の RLS が効くので、自分の注文の明細だけが残る
ALTER TABLE order_items ENABLE ROW LEVEL SECURITY;
CREATE POLICY p_order_items_self ON order_items
    FOR SELECT TO analyst
    USING (order_id IN (SELECT id FROM orders));
-- 注: payments・shipments・returns など注文にひもづくほかの表は、この例では RLS の対象外。
--     本番で会員ごとに隠すなら、同じ形のポリシーを足す

-- 動作確認: 注文のある会員を1人選び、その会員として数える
SELECT user_id AS sample_user FROM orders ORDER BY ordered_at DESC LIMIT 1 \gset
SET LOCAL ROLE analyst;
SELECT count(*) AS orders_without_setting FROM orders;          -- 未設定 → 0
SELECT set_config('app.current_user_id', :'sample_user', true);
SELECT count(*) AS orders_visible FROM orders;                  -- その会員の注文だけ
SELECT count(*) AS items_visible FROM order_items;              -- その会員の明細だけ
SELECT set_config('app.current_user_id', '', true);
SELECT count(*) AS orders_after_reset FROM orders;              -- 空文字 → 0（エラーにならない）
RESET ROLE;

-- ===== 監査ログ =====
CREATE TABLE audit_logs (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    user_name text NOT NULL,
    action text NOT NULL,
    table_name text NOT NULL,
    record_id uuid,
    old_value jsonb,
    new_value jsonb,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION audit_trigger() RETURNS trigger
LANGUAGE plpgsql AS
$fn$
BEGIN
    INSERT INTO audit_logs (user_name, action, table_name, record_id, old_value, new_value)
    VALUES (current_user, TG_OP, TG_TABLE_NAME,
            COALESCE((to_jsonb(NEW)->>'id')::uuid, (to_jsonb(OLD)->>'id')::uuid),
            to_jsonb(OLD), to_jsonb(NEW));
    RETURN COALESCE(NEW, OLD);
END;
$fn$;

CREATE TRIGGER users_audit
AFTER INSERT OR UPDATE OR DELETE ON users
FOR EACH ROW EXECUTE FUNCTION audit_trigger();

-- 動作確認: ランクを変えると、変更前後が監査ログに残る（updated_at はトリガーで自動更新）
UPDATE users SET rank = 'platinum' WHERE email = 'user_1@example.com';   -- gold → platinum
SELECT user_name, action, table_name,
       old_value->>'rank' AS old_rank, new_value->>'rank' AS new_rank,
       (new_value->>'updated_at')::timestamptz > (old_value->>'updated_at')::timestamptz AS updated_at_moved
FROM audit_logs;

-- ===== プライバシー・品質 =====
-- 匿名化（メールをSHA256で不可逆化）
SELECT encode(digest(email, 'sha256'), 'hex') AS anon_email
FROM users ORDER BY email LIMIT 5;

-- 品質チェック（NULL・負値・金額の内訳の横断）
SELECT 'users_null_email' AS chk, count(*) FROM users WHERE email IS NULL
UNION ALL
SELECT 'orders_negative_amount', count(*) FROM orders WHERE amount < 0
UNION ALL
SELECT 'orders_breakdown_mismatch', count(*) FROM orders
WHERE amount <> subtotal - discount_amount + shipping_fee;

ROLLBACK;   -- すべて取り消す（ロール・権限・RLS・トリガー・監査表・拡張）
