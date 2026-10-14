-- 04b_generators.sql — 造数の共通手続き（第5章・付録C）
-- codes/sql-code/init/04b_generators.sql@v1.2.2
-- 05（small）・06（medium）・07（large）・08（xlarge）が同じ業務ルールでデータを作るための手続き。
-- 規模ごとに書き分けると、ルールが少しずつずれる（v1.1.1 までの反省）。ここに1か所でまとめる。
--
-- 業務ルール（このファイルが作るデータの約束）
--   * 会員: ランクは番号で決める（platinum 1% / gold 5% / silver 20% / bronze 74%）。
--           住所は全員に「自宅」1件（既定）、約2割に「勤務先」をもう1件。
--   * 商品: 価格は300〜5万円の範囲で、安い商品ほど多い（1,980円のような「〜80円」）。在庫は約3%が0。
--           英語名は約2割が未登録（NULL）。在庫変動履歴に初回入荷（restock）を1行。
--   * 注文: 会員登録より後の日時に注文する。時間帯は昼と夜に山がある。
--           明細は1〜p_max_items行（同じ商品は1行にまとめる）。
--           売れ筋の偏りを少し付ける（商品番号の若いほうがよく売れる）。
--           状態は時刻の流れで決める: 注文受付 → 決済（カード・PayPalは数分、コンビニ払いは1〜72時間）
--           → 発送（決済の6〜48時間後）→ 配達（発送の18〜72時間後）。
--           約2%は取消（受付の1〜72時間後。決済前の取消はコンビニ払いの期限切れ）、
--           約2.5%は返品（配達の2〜10日後）。「今」より後の出来事はまだ起きていない
--           → 直近の注文には ordered（未決済）・paid・shipped が残る。
--   * 金額: 小計 = Σ 数量×単価。クーポンは約12%の注文で試し、最低小計に届き上限が残っていれば使う。
--           送料 = 小計5000円未満なら500円。請求額 = 小計 - 値引き + 送料。
--   * 状態履歴: 起きた出来事ごとに1行（order_status_histories）。
--   * 決済: ordered 以外の注文に1件。決済額 = 請求額。取消は決済前なら failed、決済後なら refunded。
--   * 発送: shipped / delivered / returned の注文に1件。配送先は既定住所の写し。
--   * 返品: returned の注文に1件。返金額 = 請求額（お客様都合の返品は送料を返さない）。
--   * レビュー: delivered の注文の一部（p_review_rate）に、明細の1商品について1件。
--   * 行動ログ: 時刻の順に追記する（ログは追記型。物理的な並びと created_at がそろう → BRIN が効く）。
--   * 乱数: random() だけを使う。呼び出す側で SELECT setseed(...) すれば、会員・住所・商品は同じ内容になる
--     （id と時刻は除く）。注文は時間帯の山を日本時間の日付で付けるため、投入した時刻によって
--     状態・件数の内訳が少し変わる（例: medium の returned が 2485 件と 2494 件）。
--   * 割当は配列インデックス方式か、番号（idx）付きの一時表との結合で行う
--     （v1.1.0 の教訓: 無相関の副問合せは1回しか評価されず、全行が同じ値になる）。
-- 注意: 手続きの中で COMMIT するので、トランザクションの外で CALL する（psql の既定の自動コミットでよい）。

SET search_path TO sakura, public;

-- ---------------------------------------------------------------
-- gen_users: 会員と住所を作る
--   p_email_prefix: メールの接頭辞（例 'user_medium_' → user_medium_1@example.com）
--   p_days: 登録日を「今」から何日前までに散らすか
-- ---------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sakura.gen_users(
    p_email_prefix text, p_name_prefix text, p_count int, p_days int)
LANGUAGE plpgsql AS
$proc$
BEGIN
    IF p_count <= 0 THEN
        RETURN;
    END IF;
    -- 都道府県は人口の多いところほど多く（20枠に重みを付けて割る）
    WITH pref(k, prefecture, city, postal3) AS (
        VALUES (1, '東京都', '新宿区', '160'), (2, '神奈川県', '横浜市西区', '220'),
               (3, '大阪府', '大阪市北区', '530'), (4, '愛知県', '名古屋市中区', '460'),
               (5, '埼玉県', 'さいたま市大宮区', '330'), (6, '千葉県', '千葉市中央区', '260'),
               (7, '福岡県', '福岡市博多区', '812'), (8, '北海道', '札幌市中央区', '060'),
               (9, '兵庫県', '神戸市中央区', '650'), (10, '京都府', '京都市下京区', '600')
    ),
    ins AS (
        INSERT INTO users (email, display_name, rank, created_at, updated_at)
        SELECT p_email_prefix || g || '@example.com', p_name_prefix || g,
               CASE
                   WHEN g % 100 = 0 THEN 'platinum'
                   WHEN g % 100 < 6 THEN 'gold'
                   WHEN g % 100 < 26 THEN 'silver'
                   ELSE 'bronze'
               END,
               t, t
        FROM (SELECT g,
                     now() - interval '1 day' * (g % p_days)
                           - interval '1 second' * floor(random() * 86400) AS t
              FROM generate_series(1, p_count) AS g) AS s
        RETURNING id, created_at
    ),
    home AS (
        INSERT INTO addresses (user_id, label, postal_code, prefecture, city, street,
                               is_default, created_at, updated_at)
        SELECT a.id, '自宅', p.postal3 || '-' || lpad(a.n4::text, 4, '0'),
               p.prefecture, p.city, a.street, true, a.created_at, a.created_at
        FROM (SELECT id, created_at,
                     (ARRAY[1,1,1,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,9,10])[1 + floor(random() * 20)::int] AS k,
                     floor(random() * 10000)::int AS n4,
                     (1 + floor(random() * 5)::int) || '-' || (1 + floor(random() * 30)::int)
                         || '-' || (1 + floor(random() * 20)::int) AS street
              FROM ins) AS a
        JOIN pref p ON p.k = a.k
        RETURNING user_id
    )
    -- 約2割の会員に勤務先（既定ではない）
    INSERT INTO addresses (user_id, label, postal_code, prefecture, city, street,
                           is_default, created_at, updated_at)
    SELECT a.id, '勤務先', p.postal3 || '-' || lpad(a.n4::text, 4, '0'),
           p.prefecture, p.city, a.street, false, a.created_at, a.created_at
    FROM (SELECT id, created_at, r,
                 (ARRAY[1,1,1,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,9,10])[1 + floor(random() * 20)::int] AS k,
                 floor(random() * 10000)::int AS n4,
                 (1 + floor(random() * 5)::int) || '-' || (1 + floor(random() * 30)::int)
                     || '-' || (1 + floor(random() * 20)::int) AS street
          FROM (SELECT id, created_at, random() AS r FROM ins) AS x) AS a
    JOIN pref p ON p.k = a.k
    WHERE a.r < 0.2;
END;
$proc$;

-- ---------------------------------------------------------------
-- gen_products: 商品と在庫を作る
--   SKU は p_sku_prefix || 0埋め番号（例 'SKU-M-' と 5桁 → SKU-M-00001）
-- ---------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sakura.gen_products(
    p_sku_prefix text, p_name_prefix text, p_pad int, p_count int)
LANGUAGE plpgsql AS
$proc$
DECLARE
    v_cats uuid[];
    v_sellers uuid[];
    v_n_cats int;
    v_n_sellers int;
BEGIN
    IF p_count <= 0 THEN
        RETURN;
    END IF;
    -- 配列はキーの順で固定（並びが変わると、同じ乱数でも割当が変わる）
    SELECT array_agg(id ORDER BY name) INTO v_cats FROM categories;
    SELECT array_agg(id ORDER BY email) INTO v_sellers FROM sellers;
    v_n_cats := array_length(v_cats, 1);
    v_n_sellers := array_length(v_sellers, 1);

    WITH ins AS (
        INSERT INTO products (sku, name_ja, name_en, price, category_id, seller_id,
                              created_at, updated_at)
        SELECT p_sku_prefix || lpad(g::text, p_pad, '0'),
               p_name_prefix || g,
               -- 英語名は約2割が未登録（NULL）。翻訳が追いついていない商品がある
               CASE WHEN random() < 0.2 THEN NULL
                    ELSE 'Product ' || replace(p_sku_prefix, 'SKU-', '') || g END,
               -- 300〜5万円の対数一様（安い商品ほど多い）を100円単位にして「〜80円」に
               GREATEST(100, (round(exp(ln(300) + random() * ln(50000.0 / 300)) / 100) * 100)::int - 20),
               v_cats[1 + floor(random() * v_n_cats)::int],
               v_sellers[1 + floor(random() * v_n_sellers)::int],
               now() - interval '1100 days', now() - interval '1100 days'
        FROM generate_series(1, p_count) AS g
        RETURNING id, created_at
    ),
    stk AS (
        SELECT id, created_at,
               CASE WHEN random() < 0.03 THEN 0 ELSE 1 + floor(random() * 200)::int END AS stock
        FROM ins
    ),
    inv AS (
        INSERT INTO inventory (product_id, stock)
        SELECT id, stock FROM stk
        RETURNING product_id
    )
    -- 在庫変動履歴: 初回入荷（restock）を1行。在庫数 = 履歴の change の合計 になる
    INSERT INTO inventory_logs (product_id, change, reason, created_at)
    SELECT id, stock, 'restock', created_at FROM stk WHERE stock > 0;
END;
$proc$;

-- ---------------------------------------------------------------
-- gen_user_pool: 会員を登録日の順に番号付けした一時表 tmp_gen_users を作り、
--   「ある日より前に登録した会員の人数」の累積配列を返す（注文・ログは登録後の会員だけに割り当てる）
--   戻り値 cum[i] = v_base + (i-1)日 より前に登録した会員数（i = 1..p_days+1）
-- ---------------------------------------------------------------
CREATE OR REPLACE FUNCTION sakura.gen_user_pool(p_base timestamptz, p_days int)
RETURNS int[]
LANGUAGE plpgsql AS
$fn$
DECLARE
    v_cum int[];
BEGIN
    IF to_regclass('pg_temp.tmp_gen_users') IS NOT NULL THEN
        DROP TABLE tmp_gen_users;
    END IF;
    CREATE TEMP TABLE tmp_gen_users AS
    SELECT row_number() OVER (ORDER BY u.created_at, u.email)::int AS idx,
           u.id AS user_id, u.created_at,
           a.id AS address_id, a.postal_code, a.prefecture, a.city, a.street
    FROM users u
    LEFT JOIN addresses a ON a.user_id = u.id AND a.is_default
    WHERE u.deleted_at IS NULL;
    ALTER TABLE tmp_gen_users ADD PRIMARY KEY (idx);
    ANALYZE tmp_gen_users;

    WITH b AS (
        SELECT GREATEST(floor(extract(epoch FROM created_at - p_base) / 86400)::int + 2, 1) AS j,
               count(*) AS c
        FROM tmp_gen_users GROUP BY 1
    )
    SELECT array_agg(cs ORDER BY i) INTO v_cum
    FROM (SELECT d.i, (sum(COALESCE(b.c, 0)) OVER (ORDER BY d.i))::int AS cs
          FROM generate_series(1, p_days + 1) AS d(i)
          LEFT JOIN b ON b.j = d.i) AS x;
    RETURN v_cum;
END;
$fn$;

-- ---------------------------------------------------------------
-- gen_orders: 注文・明細・状態履歴・決済・発送・返品・レビューを作り、クーポンの使用回数をそろえる
--   p_count: 注文数 / p_days: 何日前から今までに散らすか / p_max_items: 1注文の明細行の上限
--   p_batch_size: 1回にまとめて作る注文数（ごとに COMMIT）
--   注文は時刻の順に作る（第b回は期間の b 番目の区間）。実際の注文と同じく、古い注文ほど表の前に並ぶ。
-- ---------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sakura.gen_orders(
    p_count int, p_days int, p_max_items int,
    p_batch_size int DEFAULT 100000,
    p_review_rate float8 DEFAULT 0.1,
    p_coupon_rate float8 DEFAULT 0.12)
LANGUAGE plpgsql AS
$proc$
DECLARE
    v_base timestamptz := now() - interval '1 day' * p_days;
    v_span interval := interval '1 day' * p_days;
    v_cum int[];
    v_np int;
    v_cp_id uuid[];
    v_cp_pct boolean[];
    v_cp_value int[];
    v_cp_min int[];
    v_cp_rem int[];
    v_nc int;
    v_nb int;
    v_n int;
    v_slice_start timestamptz;
    v_slice interval;
    v_t0 timestamptz;
    v_hours int[];
    v_nh int;
    r record;
    b int;
BEGIN
    IF p_count <= 0 THEN
        RETURN;
    END IF;
    v_cum := sakura.gen_user_pool(v_base, p_days);

    IF to_regclass('pg_temp.tmp_gen_products') IS NOT NULL THEN
        DROP TABLE tmp_gen_products;
    END IF;
    CREATE TEMP TABLE tmp_gen_products AS
    SELECT row_number() OVER (ORDER BY sku)::int AS idx, id AS product_id, price
    FROM products WHERE deleted_at IS NULL;
    ALTER TABLE tmp_gen_products ADD PRIMARY KEY (idx);
    ANALYZE tmp_gen_products;
    SELECT count(*) INTO v_np FROM tmp_gen_products;

    -- クーポン（10枚程度なので配列で持つ）。残り回数 = 上限 - これまでの使用（取消分も含めて数え、上限を超えないように）
    SELECT array_agg(c.id ORDER BY c.code),
           array_agg(c.discount_type = 'percentage' ORDER BY c.code),
           array_agg(c.discount_value ORDER BY c.code),
           array_agg(c.min_purchase ORDER BY c.code),
           array_agg(c.max_uses - (SELECT count(*) FROM orders o WHERE o.coupon_id = c.id)::int
                     ORDER BY c.code)
      INTO v_cp_id, v_cp_pct, v_cp_value, v_cp_min, v_cp_rem
    FROM coupons c;
    v_nc := COALESCE(array_length(v_cp_id, 1), 0);

    v_nb := ceil(p_count::numeric / p_batch_size)::int;
    v_slice := v_span / v_nb;

    -- 時間帯の重み（0〜23時、JST）。重みの数だけ時刻を並べた配列から1つ引く
    SELECT array_agg(h ORDER BY h, k), count(*) INTO v_hours, v_nh
    FROM unnest(ARRAY[2,1,1,1,1,1,2,3,4,4,5,6,8,6,5,5,5,5,6,7,9,10,9,5]) WITH ORDINALITY AS w(wt, h1)
    CROSS JOIN LATERAL generate_series(1, w.wt) AS k
    CROSS JOIN LATERAL (SELECT (w.h1 - 1)::int AS h) AS hh;

    FOR b IN 1..v_nb LOOP
        v_t0 := clock_timestamp();
        v_n := LEAST(p_batch_size, p_count - (b - 1) * p_batch_size);
        v_slice_start := v_base + v_slice * (b - 1);

        -- (1) 注文の骨格: 日時・会員・出来事の予定時刻（乱数は1行ずつ評価される SELECT 句に置く）
        CREATE TEMP TABLE tmp_o ON COMMIT DROP AS
        SELECT g, t AS ordered_at,
               1 + floor(r_user * GREATEST(v_cum[LEAST(GREATEST(
                   floor(extract(epoch FROM t - v_base) / 86400)::int + 1, 1), p_days + 1)], 1))::int AS user_idx,
               1 + floor(r_lines * p_max_items)::int AS n_lines,
               fate, method, t_paid, t_cancel, t_ship, t_deliv,
               CASE WHEN fate = 'return' THEN t_deliv + interval '1 day' * (2 + r_ret * 8) END AS t_ret,
               CASE WHEN v_nc > 0 AND r_coupon < p_coupon_rate
                    THEN 1 + floor(r_cidx * v_nc)::int END AS coupon_idx,
               r_review, r_carrier
        FROM (
            SELECT g, t, r_user, r_lines, fate, method, r_ret, r_coupon, r_cidx, r_review, r_carrier,
                   t_paid,
                   CASE WHEN fate = 'cancel' THEN t + interval '1 hour' * (1 + r_cancel * 71) END AS t_cancel,
                   t_paid + interval '1 hour' * (6 + r_ship * 42) AS t_ship,
                   t_paid + interval '1 hour' * (6 + r_ship * 42)
                          + interval '1 hour' * (18 + r_deliv * 54) AS t_deliv
            FROM (
                SELECT g, t, r_user, r_lines, r_ret, r_coupon, r_cidx, r_review, r_carrier,
                       r_cancel, r_ship, r_deliv,
                       CASE WHEN r_fate < 0.02 THEN 'cancel'
                            WHEN r_fate < 0.045 THEN 'return' ELSE 'normal' END AS fate,
                       method,
                       t + CASE WHEN method = 'convenience_store'
                                THEN interval '1 hour' * (1 + r_pay * 71)
                                ELSE interval '1 minute' * (1 + r_pay * 29) END AS t_paid
                FROM (
                    SELECT g,
                           -- 時刻: 日付は区間内で一様、時間帯は昼(12時)と夜(20〜22時)に山を付ける（JST）。
                           -- 区間の外・「今」より後になったら、一様に引いた時刻をそのまま使う
                           CASE WHEN th BETWEEN v_base AND now() THEN th ELSE t0 END AS t,
                           random() AS r_user, random() AS r_lines, random() AS r_fate,
                           CASE WHEN m < 0.60 THEN 'credit_card'
                                WHEN m < 0.85 THEN 'convenience_store' ELSE 'paypal' END AS method,
                           random() AS r_pay, random() AS r_cancel, random() AS r_ship,
                           random() AS r_deliv, random() AS r_ret, random() AS r_coupon,
                           random() AS r_cidx, random() AS r_review, random() AS r_carrier
                    FROM (
                        SELECT g, m, t0,
                               (date_trunc('day', t0 AT TIME ZONE 'Asia/Tokyo')
                                + interval '1 hour' * v_hours[1 + floor(random() * v_nh)::int]
                                + interval '1 second' * floor(random() * 3600)) AT TIME ZONE 'Asia/Tokyo' AS th
                        FROM (SELECT g, random() AS m, v_slice_start + v_slice * random() AS t0
                              FROM generate_series(1, v_n) AS g) AS z
                    ) AS s0
                ) AS s1
            ) AS s2
        ) AS s3;

        -- (2) 明細: 1注文 n_lines 行。同じ商品が2回出たら1行にまとめて数量を足す
        CREATE TEMP TABLE tmp_i ON COMMIT DROP AS
        SELECT o.g, x.pidx, sum(x.qty)::int AS qty
        FROM tmp_o o
        CROSS JOIN LATERAL (
            SELECT 1 + floor(power(random(), 1.5) * v_np)::int AS pidx,   -- 若い番号ほど売れる
                   1 + floor(power(random(), 3) * 3)::int AS qty           -- 1個が約7割
            FROM generate_series(1, o.n_lines)
        ) AS x
        GROUP BY o.g, x.pidx;
        ANALYZE tmp_i;

        -- (3) 金額と状態を確定（クーポンは上限の残りを超えた分を外す）
        CREATE TEMP TABLE tmp_f ON COMMIT DROP AS
        WITH s AS (
            SELECT i.g, sum(i.qty * p.price)::int AS subtotal
            FROM tmp_i i JOIN tmp_gen_products p ON p.idx = i.pidx
            GROUP BY i.g
        ),
        cand AS (
            SELECT o.g, o.coupon_idx,
                   row_number() OVER (PARTITION BY o.coupon_idx ORDER BY o.g) AS rn
            FROM tmp_o o JOIN s ON s.g = o.g
            WHERE o.coupon_idx IS NOT NULL AND s.subtotal >= v_cp_min[o.coupon_idx]
        ),
        k AS (
            SELECT o.*, s.subtotal,
                   CASE WHEN cand.g IS NOT NULL
                         AND (v_cp_rem[cand.coupon_idx] IS NULL OR cand.rn <= v_cp_rem[cand.coupon_idx])
                        THEN cand.coupon_idx END AS cidx,
                   CASE
                       WHEN o.fate = 'cancel' AND o.t_cancel <= now() THEN 'cancelled'
                       WHEN o.fate = 'return' AND o.t_ret <= now() THEN 'returned'
                       WHEN o.fate <> 'cancel' AND o.t_deliv <= now() THEN 'delivered'
                       WHEN o.fate <> 'cancel' AND o.t_ship <= now() THEN 'shipped'
                       WHEN o.t_paid <= now() AND (o.fate <> 'cancel' OR o.t_paid < o.t_cancel) THEN 'paid'
                       ELSE 'ordered'
                   END AS status
            FROM tmp_o o
            JOIN s ON s.g = o.g
            LEFT JOIN cand ON cand.g = o.g
        )
        SELECT k.*,
               uuidv7(k.ordered_at - now()) AS id,      -- id の時刻部分を注文日時にそろえる（PG18）
               u.user_id, u.address_id, u.postal_code, u.prefecture, u.city, u.street,
               CASE WHEN k.cidx IS NULL THEN 0
                    WHEN v_cp_pct[k.cidx] THEN floor(k.subtotal * v_cp_value[k.cidx] / 100.0)::int
                    ELSE LEAST(v_cp_value[k.cidx], k.subtotal) END AS discount_amount,
               CASE WHEN k.subtotal < 5000 THEN 500 ELSE 0 END AS shipping_fee
        FROM k JOIN tmp_gen_users u ON u.idx = k.user_idx;
        ANALYZE tmp_f;

        -- クーポンの残り回数を減らす
        FOR r IN SELECT cidx, count(*)::int AS n FROM tmp_f WHERE cidx IS NOT NULL GROUP BY cidx LOOP
            IF v_cp_rem[r.cidx] IS NOT NULL THEN
                v_cp_rem[r.cidx] := v_cp_rem[r.cidx] - r.n;
            END IF;
        END LOOP;

        -- (4) 注文（時刻順に追記）
        INSERT INTO orders (id, user_id, status, subtotal, discount_amount, shipping_fee, amount,
                            coupon_id, ordered_at, created_at, updated_at)
        SELECT f.id, f.user_id, f.status, f.subtotal, f.discount_amount, f.shipping_fee,
               f.subtotal - f.discount_amount + f.shipping_fee,
               v_cp_id[f.cidx], f.ordered_at, f.ordered_at,
               CASE f.status
                   WHEN 'cancelled' THEN f.t_cancel WHEN 'returned' THEN f.t_ret
                   WHEN 'delivered' THEN f.t_deliv WHEN 'shipped' THEN f.t_ship
                   WHEN 'paid' THEN f.t_paid ELSE f.ordered_at END
        FROM tmp_f f
        ORDER BY f.ordered_at;

        -- (5) 明細（単価は注文時点の商品価格）
        INSERT INTO order_items (order_id, product_id, quantity, price, created_at)
        SELECT f.id, p.product_id, i.qty, p.price, f.ordered_at
        FROM tmp_i i
        JOIN tmp_f f ON f.g = i.g
        JOIN tmp_gen_products p ON p.idx = i.pidx
        ORDER BY f.ordered_at, i.pidx;

        -- (6) 状態履歴（起きた出来事だけ）
        INSERT INTO order_status_histories (order_id, from_status, to_status, changed_at, note)
        SELECT id, from_s, to_s, at, note FROM (
            SELECT f.id, NULL::varchar AS from_s, 'ordered'::varchar AS to_s,
                   f.ordered_at AS at, NULL::varchar AS note
            FROM tmp_f f
            UNION ALL
            SELECT f.id, 'ordered', 'paid', f.t_paid, NULL FROM tmp_f f
            WHERE f.status IN ('paid', 'shipped', 'delivered', 'returned')
               OR (f.status = 'cancelled' AND f.t_paid < f.t_cancel)
            UNION ALL
            SELECT f.id, 'paid', 'shipped', f.t_ship, NULL FROM tmp_f f
            WHERE f.status IN ('shipped', 'delivered', 'returned')
            UNION ALL
            SELECT f.id, 'shipped', 'delivered', f.t_deliv, NULL FROM tmp_f f
            WHERE f.status IN ('delivered', 'returned')
            UNION ALL
            SELECT f.id, 'delivered', 'returned', f.t_ret, '返品受付' FROM tmp_f f
            WHERE f.status = 'returned'
            UNION ALL
            SELECT f.id, CASE WHEN f.t_paid < f.t_cancel THEN 'paid' ELSE 'ordered' END,
                   'cancelled', f.t_cancel,
                   CASE WHEN f.t_paid < f.t_cancel THEN 'お客様都合（返金）'
                        ELSE '支払期限切れ' END
            FROM tmp_f f WHERE f.status = 'cancelled'
        ) AS h
        ORDER BY at;

        -- (7) 決済（ordered 以外。決済額 = 請求額）
        INSERT INTO payments (order_id, method, status, amount, paid_at, created_at)
        SELECT f.id, f.method,
               CASE
                   WHEN f.status = 'cancelled' AND f.t_paid < f.t_cancel THEN 'refunded'
                   WHEN f.status = 'cancelled' THEN 'failed'
                   WHEN f.status = 'returned' THEN 'refunded'
                   ELSE 'completed'
               END,
               f.subtotal - f.discount_amount + f.shipping_fee,
               CASE WHEN f.status = 'cancelled' AND f.t_paid >= f.t_cancel THEN NULL ELSE f.t_paid END,
               f.ordered_at
        FROM tmp_f f
        WHERE f.status <> 'ordered'
        ORDER BY f.ordered_at;

        -- (8) 発送（配送先は既定住所の写し）
        INSERT INTO shipments (order_id, address_id, ship_postal_code, ship_prefecture, ship_city,
                               ship_street, carrier, tracking_number, shipped_at, delivered_at, created_at)
        SELECT f.id, f.address_id, f.postal_code, f.prefecture, f.city, f.street,
               CASE WHEN f.r_carrier < 0.5 THEN 'yamato'
                    WHEN f.r_carrier < 0.8 THEN 'sagawa' ELSE 'japanpost' END,
               'TRK' || lpad(floor(random() * 10000000000)::bigint::text, 10, '0'),
               f.t_ship,
               CASE WHEN f.status IN ('delivered', 'returned') THEN f.t_deliv END,
               f.t_ship
        FROM tmp_f f
        WHERE f.status IN ('shipped', 'delivered', 'returned')
        ORDER BY f.t_ship;

        -- (9) 返品（お客様都合は送料を返さない）
        INSERT INTO returns (order_id, reason, status, refund_amount, returned_at, created_at)
        SELECT x.id, x.reason, 'refunded',
               x.amount - CASE WHEN x.reason IN ('サイズが合わない', 'イメージと違う', '注文間違い')
                               THEN x.shipping_fee ELSE 0 END,
               x.t_ret, x.t_ret
        FROM (
            SELECT f.id, f.t_ret, f.shipping_fee,
                   f.subtotal - f.discount_amount + f.shipping_fee AS amount,
                   (ARRAY['サイズが合わない', 'イメージと違う', '初期不良', '配送中の破損', '注文間違い'])
                       [1 + floor(random() * 5)::int] AS reason
            FROM tmp_f f WHERE f.status = 'returned'
        ) AS x
        ORDER BY x.t_ret;

        -- (10) レビュー（配達済みの一部。同じ会員×商品は1件まで）
        INSERT INTO reviews (user_id, product_id, rating, comment, created_at)
        SELECT y.user_id, y.product_id, y.rating,
               (ARRAY['期待外れでした', 'いまひとつ', '普通です', '満足しています', 'とても良い'])[y.rating],
               y.at
        FROM (
            SELECT x.user_id, x.product_id,
                   CASE WHEN rr < 0.07 THEN 1 WHEN rr < 0.15 THEN 2 WHEN rr < 0.30 THEN 3
                        WHEN rr < 0.60 THEN 4 ELSE 5 END AS rating,
                   x.t_deliv + interval '1 hour' * (1 + random() * 335) AS at
            FROM (
                SELECT DISTINCT ON (f.g) f.user_id, p.product_id, f.t_deliv, random() AS rr
                FROM tmp_f f
                JOIN tmp_i i ON i.g = f.g
                JOIN tmp_gen_products p ON p.idx = i.pidx
                WHERE f.status = 'delivered' AND f.r_review < p_review_rate
                ORDER BY f.g, i.pidx
            ) AS x
        ) AS y
        WHERE y.at <= now()
        ON CONFLICT (user_id, product_id) DO NOTHING;

        COMMIT;
        IF v_nb > 1 THEN
            RAISE NOTICE 'gen_orders batch % / % (% orders) % s', b, v_nb, v_n,
                round(extract(epoch FROM clock_timestamp() - v_t0)::numeric, 1);
        END IF;
    END LOOP;

    -- クーポンの使用回数 = 取り消されていない注文での使用数
    UPDATE coupons c SET used_count = (
        SELECT count(*) FROM orders o WHERE o.coupon_id = c.id AND o.status <> 'cancelled');
    COMMIT;

    DROP TABLE tmp_gen_users;
    DROP TABLE tmp_gen_products;
END;
$proc$;

-- ---------------------------------------------------------------
-- gen_behavior_logs: 行動ログを時刻の順に追記する
--   p_count 行を「p_days 日前〜今」に均等に散らし、1回 p_batch_size 行ずつ COMMIT
--   約15%は未ログイン（user_id NULL）、検索は product_id NULL・キーワードあり
-- ---------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sakura.gen_behavior_logs(
    p_count bigint, p_days int, p_batch_size int DEFAULT 1000000)
LANGUAGE plpgsql AS
$proc$
DECLARE
    v_base timestamptz := now() - interval '1 day' * p_days;
    v_span interval := interval '1 day' * p_days;
    v_cum int[];
    v_users uuid[];
    v_products uuid[];
    v_np int;
    v_nb int;
    v_n int;
    v_off bigint;
    b int;
BEGIN
    IF p_count <= 0 THEN
        RETURN;
    END IF;
    v_cum := sakura.gen_user_pool(v_base, p_days);
    SELECT array_agg(user_id ORDER BY idx) INTO v_users FROM tmp_gen_users;
    SELECT array_agg(id ORDER BY sku) INTO v_products FROM products WHERE deleted_at IS NULL;
    v_np := array_length(v_products, 1);
    v_nb := ceil(p_count::numeric / p_batch_size)::int;

    FOR b IN 1..v_nb LOOP
        v_off := (b - 1)::bigint * p_batch_size;
        v_n := LEAST(p_batch_size::bigint, p_count - v_off)::int;

        INSERT INTO behavior_logs (user_id, product_id, action, search_keyword, created_at)
        SELECT CASE WHEN r_anon < 0.15 THEN NULL
                    ELSE v_users[1 + floor(r_user * GREATEST(v_cum[LEAST(GREATEST(
                        floor(extract(epoch FROM t - v_base) / 86400)::int + 1, 1), p_days + 1)], 1))::int]
               END,
               CASE WHEN action = 'search' THEN NULL
                    ELSE v_products[1 + floor(power(r_prod, 1.5) * v_np)::int] END,
               action,
               CASE WHEN action = 'search'
                    THEN (ARRAY['スマホ', 'ノートPC', '小説', 'キッチン', 'セール', 'メンズ', '食品', 'イヤホン'])
                         [1 + floor(r_kw * 8)::int] END,
               t
        FROM (
            -- 先に 0〜1 の割合にしてから期間に掛ける（大きな数を interval に掛けると桁あふれする）
            SELECT v_base + v_span * (((v_off + g - 1) + random()) / p_count) AS t,
                   random() AS r_anon, random() AS r_user, random() AS r_prod, random() AS r_kw,
                   CASE WHEN a < 0.60 THEN 'view' WHEN a < 0.75 THEN 'add_to_cart'
                        WHEN a < 0.80 THEN 'remove_from_cart' WHEN a < 0.95 THEN 'search'
                        ELSE 'purchase' END AS action
            FROM (SELECT g, random() AS a FROM generate_series(1, v_n) AS g) AS s0
        ) AS s
        ORDER BY t;

        COMMIT;
        IF v_nb > 1 THEN
            RAISE NOTICE 'gen_behavior_logs batch % / % done', b, v_nb;
        END IF;
    END LOOP;
    DROP TABLE tmp_gen_users;
END;
$proc$;
