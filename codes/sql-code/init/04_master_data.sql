-- 04_master_data.sql — マスタ投入（第5章）
-- codes/sql-code/init/04_master_data.sql@v1.2.2
-- カテゴリ10（親5+子5）・販売者20・クーポン10・キャンペーン2。
-- マスタは乱数を使わない（何度投入しても同じ内容。id と時刻を除く）。

SET search_path TO sakura, public;

-- カテゴリ: 親5
INSERT INTO categories (id, name, parent_id, display_order) VALUES
    (uuidv7(), 'electronics', NULL, 1),
    (uuidv7(), 'fashion', NULL, 2),
    (uuidv7(), 'foods', NULL, 3),
    (uuidv7(), 'books', NULL, 4),
    (uuidv7(), 'home', NULL, 5);

-- カテゴリ: 子5（親を名前で引く）
INSERT INTO categories (id, name, parent_id, display_order)
SELECT uuidv7(), c.name, p.id, c.display_order
FROM (VALUES
    ('smartphone', 'electronics', 11),
    ('laptop', 'electronics', 12),
    ('mens', 'fashion', 21),
    ('novel', 'books', 41),
    ('kitchen', 'home', 51)
) AS c (name, pname, display_order)
JOIN categories p ON p.name = c.pname AND p.parent_id IS NULL;

-- 販売者20（決定的）
INSERT INTO sellers (name, email, commission_rate)
SELECT 'seller_' || g, 'seller_' || g || '@example.com', 0.05 + (g % 10) * 0.01
FROM generate_series(1, 20) AS g;

-- クーポン10
--   偶数番: percentage（5〜20%引き）、奇数番: fixed（500〜2500円引き）
--   使える最低小計 min_purchase: 0 / 1000 / 2000 円
--   上限 max_uses: 3の倍数番（CPN0003/0006/0009）は1000回まで、ほかは上限なし（NULL）
--   発行日 created_at: 2年前（過去2年分の注文で使われるため）
INSERT INTO coupons (code, discount_type, discount_value, min_purchase, max_uses,
                     expires_at, created_at)
SELECT
    'CPN' || lpad(g::text, 4, '0'),
    CASE WHEN g % 2 = 0 THEN 'percentage' ELSE 'fixed' END,
    CASE WHEN g % 2 = 0 THEN 5 + (g % 4) * 5 ELSE 500 + (g % 5) * 500 END,
    (g % 3) * 1000,
    CASE WHEN g % 3 = 0 THEN 1000 END,
    now() + (interval '1 day' * (30 + g)),
    now() - interval '800 days'
FROM generate_series(1, 10) AS g;

-- キャンペーン2＋中間表（先頭3クーポンを束ねる例）
--   spring_sale = CPN0001・CPN0002、new_user_cp = CPN0001〜CPN0003
INSERT INTO campaigns (name, start_at, end_at) VALUES
    ('spring_sale', now() - interval '10 days', now() + interval '20 days'),
    ('new_user_cp', now() - interval '5 days', now() + interval '25 days');

-- row_number() には必ず ORDER BY を付ける（無いと番号の振り方が実行ごとに変わりうる）
INSERT INTO campaign_coupons (campaign_id, coupon_id)
SELECT camp.id, coup.id
FROM (SELECT id, row_number() OVER (ORDER BY name DESC) AS rn FROM campaigns) AS camp
JOIN (SELECT id, row_number() OVER (ORDER BY code) AS rn FROM coupons) AS coup
  ON coup.rn <= 2 OR (camp.rn = 2 AND coup.rn = 3);
