-- 02_tables.sql — Sakura Market 18テーブルDDL（第4・5章）
-- codes/sql-code/init/02_tables.sql@v1.2.2
-- 方針: PKは uuid DEFAULT uuidv7()（PG18組込）、監査列 created_at/updated_at、
-- 主要テーブルに deleted_at（論理削除）。時刻は timestamptz。
-- 作成順はFK依存順。ER図の詳細は books/ai-sql/企画/04章を参照。
--
-- v1.2.0 で業務に合わせて直した点（理由は各表のコメントに書く）
--   * orders: 金額の内訳（subtotal / discount_amount / shipping_fee）を持ち、amount（請求額）と式で結ぶ
--   * order_status_histories（新表）: 注文の状態がいつ変わったかを残す（「いつキャンセルされたか」に答える）
--   * shipments: 配送先住所の写しを持つ（住所を後で直しても、過去の配送先は変わらない）
--   * categories: 同じ親の下に同名カテゴリを作らせない
--   * addresses: 1ユーザーの既定住所は1件だけ
--   * coupons: 使用回数が上限を超えない
--   * returns: 返金額を持つ / payments: 決済額を持つ（注文の請求額と照合できる）
--   * order_items: 同じ注文に同じ商品は1行（数量でまとめる）
--   * updated_at を自動で更新するトリガー
-- v1.2.2 で全列に列コメントを補完（動作・データ不変。COMMENT ON COLUMN のみ追加）

SET search_path TO sakura, public;

-- ============ 共通: updated_at の自動更新 ============
-- 行を UPDATE したとき、updated_at を「今」に書き換える。
-- アプリが updated_at を入れ忘れても、最終更新日時が正しく残る。
CREATE OR REPLACE FUNCTION set_updated_at() RETURNS trigger
LANGUAGE plpgsql AS
$fn$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$fn$;
COMMENT ON FUNCTION set_updated_at() IS 'BEFORE UPDATE トリガー: updated_at を現在時刻にする';

-- ============ ユーザー ============
CREATE TABLE users (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    email varchar(255) NOT NULL UNIQUE,
    display_name varchar(100) NOT NULL,
    rank varchar(20) NOT NULL DEFAULT 'bronze'
        CHECK (rank IN ('bronze', 'silver', 'gold', 'platinum')),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz
);
COMMENT ON TABLE users IS 'ユーザー（会員）';
COMMENT ON COLUMN users.email IS 'メールアドレス（ログインID）';
COMMENT ON COLUMN users.display_name IS '表示名（画面や帳票で「顧客名」として出す）';
COMMENT ON COLUMN users.rank IS '会員ランク（bronze/silver/gold/platinum、小文字）';
COMMENT ON COLUMN users.deleted_at IS '退会日時（論理削除。NULLなら有効会員）';
COMMENT ON COLUMN users.id IS '主キー（uuidv7で自動採番）';
COMMENT ON COLUMN users.created_at IS '登録日時';
COMMENT ON COLUMN users.updated_at IS '最終更新日時（トリガーで自動更新）';

CREATE TABLE addresses (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    user_id uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    label varchar(50) NOT NULL,
    postal_code varchar(10) NOT NULL,
    prefecture varchar(50) NOT NULL,
    city varchar(100) NOT NULL,
    street varchar(255) NOT NULL,
    is_default boolean NOT NULL DEFAULT false,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE addresses IS '住所（1ユーザー複数可。届け先の候補）';
COMMENT ON COLUMN addresses.is_default IS '既定の届け先か（1ユーザーにつき1件だけ true）';
COMMENT ON COLUMN addresses.id IS '主キー（uuidv7で自動採番）';
COMMENT ON COLUMN addresses.user_id IS '住所の持ち主（usersへの参照。ユーザー削除で住所も消える）';
COMMENT ON COLUMN addresses.label IS '住所の呼び名（自宅・実家など）';
COMMENT ON COLUMN addresses.postal_code IS '郵便番号';
COMMENT ON COLUMN addresses.prefecture IS '都道府県';
COMMENT ON COLUMN addresses.city IS '市区町村';
COMMENT ON COLUMN addresses.street IS '番地・建物名以降';
COMMENT ON COLUMN addresses.created_at IS '登録日時';
COMMENT ON COLUMN addresses.updated_at IS '最終更新日時（トリガーで自動更新）';
-- 業務ルール: 既定の届け先は1人1件。2件 true だと「どこに送るか」が決まらない。
-- 部分一意索引で「is_default = true の行の中で user_id が重複しない」を保証する。
CREATE UNIQUE INDEX uq_addresses_default_per_user ON addresses (user_id) WHERE is_default;

-- ============ 商品 ============
CREATE TABLE sellers (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    name varchar(255) NOT NULL,
    email varchar(255) NOT NULL UNIQUE,
    commission_rate numeric(5, 4) NOT NULL DEFAULT 0.10
        CHECK (commission_rate >= 0 AND commission_rate <= 1),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE sellers IS '販売者（出品者）';
COMMENT ON COLUMN sellers.commission_rate IS '販売手数料率（0.05 = 5%）';
COMMENT ON COLUMN sellers.id IS '主キー（uuidv7で自動採番）';
COMMENT ON COLUMN sellers.name IS '販売者名';
COMMENT ON COLUMN sellers.email IS '連絡用メールアドレス（重複不可）';
COMMENT ON COLUMN sellers.created_at IS '登録日時';
COMMENT ON COLUMN sellers.updated_at IS '最終更新日時（トリガーで自動更新）';

CREATE TABLE categories (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    name varchar(100) NOT NULL,
    parent_id uuid REFERENCES categories (id),
    display_order integer NOT NULL DEFAULT 0,
    created_at timestamptz NOT NULL DEFAULT now(),
    -- 同じ親の下に同じ名前のカテゴリを作らせない（売上表で同名が2行に割れるのを防ぐ）。
    -- 最上位（parent_id が NULL）どうしも重複させないため NULLS NOT DISTINCT（PG15+）。
    CONSTRAINT uq_categories_parent_name UNIQUE NULLS NOT DISTINCT (parent_id, name)
);
COMMENT ON TABLE categories IS 'カテゴリ（parent_id NULL=最上位の階層構造）';
COMMENT ON COLUMN categories.id IS '主キー（uuidv7で自動採番）';
COMMENT ON COLUMN categories.name IS 'カテゴリ名（同じ親の中では重複不可）';
COMMENT ON COLUMN categories.parent_id IS '親カテゴリ（NULLは最上位。categoriesへの自己参照）';
COMMENT ON COLUMN categories.display_order IS '表示順（小さいほど先に表示）';
COMMENT ON COLUMN categories.created_at IS '登録日時';

CREATE TABLE products (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    sku varchar(50) NOT NULL UNIQUE,
    name_ja varchar(255) NOT NULL,
    name_en varchar(255),
    name_zh varchar(255),
    price integer NOT NULL CHECK (price >= 0),
    category_id uuid NOT NULL REFERENCES categories (id),
    seller_id uuid NOT NULL REFERENCES sellers (id),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz
);
COMMENT ON TABLE products IS '商品（SKU単位。price は現在の販売価格。注文時の価格は order_items.price）';
COMMENT ON COLUMN products.deleted_at IS '販売終了日時（論理削除。過去の注文明細から参照されるので物理削除しない）';
COMMENT ON COLUMN products.id IS '主キー（uuidv7で自動採番）';
COMMENT ON COLUMN products.sku IS '商品コード（重複不可）';
COMMENT ON COLUMN products.name_ja IS '商品名（日本語）';
COMMENT ON COLUMN products.name_en IS '商品名（英語。NULL可）';
COMMENT ON COLUMN products.name_zh IS '商品名（中国語。NULL可）';
COMMENT ON COLUMN products.price IS '現在の販売価格（円。注文時の価格はorder_items.priceに写す）';
COMMENT ON COLUMN products.category_id IS '所属カテゴリ（categoriesへの参照）';
COMMENT ON COLUMN products.seller_id IS '出品者（sellersへの参照）';
COMMENT ON COLUMN products.created_at IS '登録日時';
COMMENT ON COLUMN products.updated_at IS '最終更新日時（トリガーで自動更新）';

CREATE TABLE inventory (
    product_id uuid PRIMARY KEY REFERENCES products (id) ON DELETE CASCADE,
    stock integer NOT NULL DEFAULT 0 CHECK (stock >= 0),
    updated_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE inventory IS '在庫（productsと1対1、PK兼FK）';
COMMENT ON COLUMN inventory.product_id IS '商品（productsへの参照を兼ねた主キー。1商品に1行）';
COMMENT ON COLUMN inventory.stock IS '在庫数（0以上）';
COMMENT ON COLUMN inventory.updated_at IS '最終更新日時（トリガーで自動更新）';

CREATE TABLE inventory_logs (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    product_id uuid NOT NULL REFERENCES products (id),
    change integer NOT NULL,
    reason varchar(50) NOT NULL
        CHECK (reason IN ('order', 'cancel', 'return', 'restock', 'adjustment')),
    created_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE inventory_logs IS '在庫変動履歴（change: プラス=入庫、マイナス=出庫）';
COMMENT ON COLUMN inventory_logs.id IS '主キー（uuidv7で自動採番）';
COMMENT ON COLUMN inventory_logs.product_id IS '対象商品（productsへの参照）';
COMMENT ON COLUMN inventory_logs.change IS '増減数（プラスは入庫、マイナスは出庫）';
COMMENT ON COLUMN inventory_logs.reason IS '理由（orderは注文出庫、cancelは取消戻し、returnは返品戻し、restockは仕入れ、adjustmentは棚卸調整）';
COMMENT ON COLUMN inventory_logs.created_at IS '記録日時';

-- ============ マーケティング ============
CREATE TABLE coupons (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    code varchar(50) NOT NULL UNIQUE,
    discount_type varchar(20) NOT NULL CHECK (discount_type IN ('percentage', 'fixed')),
    discount_value integer NOT NULL CHECK (discount_value > 0),
    min_purchase integer NOT NULL DEFAULT 0 CHECK (min_purchase >= 0),
    max_uses integer CHECK (max_uses IS NULL OR max_uses > 0),
    used_count integer NOT NULL DEFAULT 0 CHECK (used_count >= 0),
    expires_at timestamptz NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    -- 発行枚数（max_uses）を超えて使わせない。NULL は上限なし。
    CONSTRAINT coupons_used_within_max CHECK (max_uses IS NULL OR used_count <= max_uses)
);
COMMENT ON TABLE coupons IS 'クーポン';
COMMENT ON COLUMN coupons.discount_type IS 'percentage=小計の◯%引き / fixed=◯円引き';
COMMENT ON COLUMN coupons.min_purchase IS '使える最低の小計（円）';
COMMENT ON COLUMN coupons.max_uses IS '使える回数の上限（NULL=上限なし）';
COMMENT ON COLUMN coupons.used_count IS '使われた回数（取り消された注文の分は数えない）';
COMMENT ON COLUMN coupons.id IS '主キー（uuidv7で自動採番）';
COMMENT ON COLUMN coupons.code IS 'クーポンコード（注文時に入力する文字列。重複不可）';
COMMENT ON COLUMN coupons.discount_value IS '値引き量（percentageならパーセント、fixedなら円）';
COMMENT ON COLUMN coupons.expires_at IS '有効期限（この日時を過ぎると使えない）';
COMMENT ON COLUMN coupons.created_at IS '発行日時';

CREATE TABLE campaigns (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    name varchar(255) NOT NULL,
    start_at timestamptz NOT NULL,
    end_at timestamptz NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    CHECK (end_at > start_at)
);
COMMENT ON TABLE campaigns IS 'キャンペーン（複数クーポンの束ね）';
COMMENT ON COLUMN campaigns.id IS '主キー（uuidv7で自動採番）';
COMMENT ON COLUMN campaigns.name IS 'キャンペーン名';
COMMENT ON COLUMN campaigns.start_at IS '開始日時';
COMMENT ON COLUMN campaigns.end_at IS '終了日時（開始より後）';
COMMENT ON COLUMN campaigns.created_at IS '登録日時';

CREATE TABLE campaign_coupons (
    campaign_id uuid NOT NULL REFERENCES campaigns (id) ON DELETE CASCADE,
    coupon_id uuid NOT NULL REFERENCES coupons (id) ON DELETE CASCADE,
    PRIMARY KEY (campaign_id, coupon_id)
);
COMMENT ON TABLE campaign_coupons IS 'キャンペーンとクーポンの多対多・中間表';
COMMENT ON COLUMN campaign_coupons.campaign_id IS 'キャンペーン（campaignsへの参照。複合主キーの片方）';
COMMENT ON COLUMN campaign_coupons.coupon_id IS 'クーポン（couponsへの参照。複合主キーの片方）';

-- ============ 注文 ============
-- 金額の内訳: amount（請求額）= subtotal（明細合計）- discount_amount（クーポン値引き）+ shipping_fee（送料）
-- 内訳を持たないと「値引きでいくら減ったか」「送料はいくら入ったか」に答えられない。
-- 式は CHECK で守るので、内訳と請求額が食い違う行は入らない。
CREATE TABLE orders (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    user_id uuid NOT NULL REFERENCES users (id),
    status varchar(20) NOT NULL DEFAULT 'ordered'
        CHECK (status IN ('ordered', 'paid', 'shipped', 'delivered', 'cancelled', 'returned')),
    subtotal integer NOT NULL CHECK (subtotal >= 0),
    discount_amount integer NOT NULL DEFAULT 0 CHECK (discount_amount >= 0),
    shipping_fee integer NOT NULL DEFAULT 0 CHECK (shipping_fee >= 0),
    amount integer NOT NULL CHECK (amount >= 0),
    coupon_id uuid REFERENCES coupons (id),
    ordered_at timestamptz NOT NULL DEFAULT now(),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT orders_amount_breakdown CHECK (amount = subtotal - discount_amount + shipping_fee),
    CONSTRAINT orders_discount_within_subtotal CHECK (discount_amount <= subtotal)
);
COMMENT ON TABLE orders IS '注文（1回の購入。金額は注文時点の確定値）';
COMMENT ON COLUMN orders.status IS '今の状態: ordered=注文受付(未決済) → paid=決済済 → shipped=発送済 → delivered=配達済。途中で cancelled=取消 / 配達後に returned=返品';
COMMENT ON COLUMN orders.subtotal IS '小計（明細の 数量×単価 の合計）';
COMMENT ON COLUMN orders.discount_amount IS 'クーポン値引き額（使わなければ0）';
COMMENT ON COLUMN orders.shipping_fee IS '送料（小計5000円未満は500円、以上は無料）';
COMMENT ON COLUMN orders.amount IS '請求額 = 小計 - 値引き + 送料（顧客が払う額。決済額と一致する）';
COMMENT ON COLUMN orders.ordered_at IS '注文日時（期間集計の基準）';
COMMENT ON COLUMN orders.id IS '主キー（uuidv7で自動採番）';
COMMENT ON COLUMN orders.user_id IS '購入者（usersへの参照）';
COMMENT ON COLUMN orders.coupon_id IS '使ったクーポン（NULLは未使用。couponsへの参照）';
COMMENT ON COLUMN orders.created_at IS '登録日時';
COMMENT ON COLUMN orders.updated_at IS '最終更新日時（トリガーで自動更新）';

-- 注文状態の履歴: 状態が変わるたびに1行足す（上書きしない）。
-- orders.status は「今の状態」だけなので、「いつ払われたか」「いつキャンセルされたか」は履歴から引く。
CREATE TABLE order_status_histories (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    order_id uuid NOT NULL REFERENCES orders (id) ON DELETE CASCADE,
    from_status varchar(20)
        CHECK (from_status IN ('ordered', 'paid', 'shipped', 'delivered', 'cancelled', 'returned')),
    to_status varchar(20) NOT NULL
        CHECK (to_status IN ('ordered', 'paid', 'shipped', 'delivered', 'cancelled', 'returned')),
    changed_at timestamptz NOT NULL DEFAULT now(),
    note varchar(255),
    CHECK (from_status IS DISTINCT FROM to_status)
);
COMMENT ON TABLE order_status_histories IS '注文状態の履歴（1注文に複数行。最初の行は from_status が NULL＝注文受付）';
COMMENT ON COLUMN order_status_histories.changed_at IS '状態が変わった日時（例: to_status=cancelled の行の changed_at がキャンセル日時）';
COMMENT ON COLUMN order_status_histories.note IS '補足（キャンセル理由など）';
COMMENT ON COLUMN order_status_histories.id IS '主キー（uuidv7で自動採番）';
COMMENT ON COLUMN order_status_histories.order_id IS '対象注文（ordersへの参照。注文削除で履歴も消える）';
COMMENT ON COLUMN order_status_histories.from_status IS '変わる前の状態（NULLは注文受付の最初の行）';
COMMENT ON COLUMN order_status_histories.to_status IS '変わった後の状態';

CREATE TABLE order_items (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    order_id uuid NOT NULL REFERENCES orders (id) ON DELETE CASCADE,
    product_id uuid NOT NULL REFERENCES products (id),
    quantity integer NOT NULL CHECK (quantity > 0),
    price integer NOT NULL CHECK (price >= 0),
    created_at timestamptz NOT NULL DEFAULT now(),
    -- 同じ注文に同じ商品を2行に分けない（2個買ったら quantity=2 の1行）。
    -- 分かれていると「商品ごとの注文件数」を数え間違える。
    CONSTRAINT uq_order_items_order_product UNIQUE (order_id, product_id)
);
COMMENT ON TABLE order_items IS '注文明細（price は注文時の単価。商品の値上げ後も過去の売上は変わらない）';
COMMENT ON COLUMN order_items.id IS '主キー（uuidv7で自動採番）';
COMMENT ON COLUMN order_items.order_id IS '所属注文（ordersへの参照）';
COMMENT ON COLUMN order_items.product_id IS '商品（productsへの参照。同じ注文と商品の組は1行）';
COMMENT ON COLUMN order_items.quantity IS '数量（1以上。同じ商品は行を分けず数量にまとめる）';
COMMENT ON COLUMN order_items.price IS '注文時の単価（円。値上げ後もこの行の金額は変わらない）';
COMMENT ON COLUMN order_items.created_at IS '登録日時';

CREATE TABLE payments (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    order_id uuid NOT NULL UNIQUE REFERENCES orders (id) ON DELETE CASCADE,
    method varchar(30) NOT NULL
        CHECK (method IN ('credit_card', 'convenience_store', 'paypal')),
    status varchar(20) NOT NULL
        CHECK (status IN ('pending', 'completed', 'failed', 'refunded')),
    -- 決済額。注文の請求額（orders.amount）と一致するはず。照合で食い違いを見つける。
    amount integer NOT NULL CHECK (amount >= 0),
    paid_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE payments IS '決済（ordersと1対1。注文受付直後で未決済の注文にはまだ無い）';
COMMENT ON COLUMN payments.status IS 'completed=入金済 / pending=入金待ち / failed=不成立（支払期限切れ等） / refunded=返金済';
COMMENT ON COLUMN payments.amount IS '決済額（円）。orders.amount と一致する';
COMMENT ON COLUMN payments.id IS '主キー（uuidv7で自動採番）';
COMMENT ON COLUMN payments.order_id IS '対象注文（ordersへの参照。1注文に1決済）';
COMMENT ON COLUMN payments.method IS '決済手段（credit_cardはカード、convenience_storeはコンビニ、paypalはPayPal）';
COMMENT ON COLUMN payments.paid_at IS '入金日時（NULLは未入金）';
COMMENT ON COLUMN payments.created_at IS '登録日時';

CREATE TABLE shipments (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    order_id uuid NOT NULL UNIQUE REFERENCES orders (id) ON DELETE CASCADE,
    -- どの登録住所から作ったか（参考）。住所を消しても発送記録は残すので NULL 可・SET NULL。
    address_id uuid REFERENCES addresses (id) ON DELETE SET NULL,
    -- 配送先の写し: 発送時点の住所をコピーして持つ。
    -- addresses を後で直しても、過去に「どこへ送ったか」は変わらない（送り状と同じ考え方）。
    ship_postal_code varchar(10) NOT NULL,
    ship_prefecture varchar(50) NOT NULL,
    ship_city varchar(100) NOT NULL,
    ship_street varchar(255) NOT NULL,
    carrier varchar(50) NOT NULL,
    tracking_number varchar(100),
    shipped_at timestamptz,
    delivered_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE shipments IS '発送（ordersと1対1。配送先は発送時点の写し）';
COMMENT ON COLUMN shipments.address_id IS '元にした登録住所（参考。住所が消されると NULL）';
COMMENT ON COLUMN shipments.id IS '主キー（uuidv7で自動採番）';
COMMENT ON COLUMN shipments.order_id IS '対象注文（ordersへの参照。1注文に1発送）';
COMMENT ON COLUMN shipments.ship_postal_code IS '配送先郵便番号（発送時点の写し）';
COMMENT ON COLUMN shipments.ship_prefecture IS '配送先都道府県（発送時点の写し）';
COMMENT ON COLUMN shipments.ship_city IS '配送先市区町村（発送時点の写し）';
COMMENT ON COLUMN shipments.ship_street IS '配送先番地以降（発送時点の写し）';
COMMENT ON COLUMN shipments.carrier IS '配送業者';
COMMENT ON COLUMN shipments.tracking_number IS '追跡番号（NULLは発行前）';
COMMENT ON COLUMN shipments.shipped_at IS '発送日時（NULLは未発送）';
COMMENT ON COLUMN shipments.delivered_at IS '配達日時（NULLは未配達）';
COMMENT ON COLUMN shipments.created_at IS '登録日時';

CREATE TABLE returns (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    order_id uuid NOT NULL REFERENCES orders (id) ON DELETE CASCADE,
    reason varchar(255) NOT NULL,
    status varchar(20) NOT NULL
        CHECK (status IN ('requested', 'approved', 'received', 'refunded', 'rejected')),
    -- 返金額。返品でいくら返したかを金額で集計できるようにする（未返金のあいだは0）。
    refund_amount integer NOT NULL DEFAULT 0 CHECK (refund_amount >= 0),
    returned_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE returns IS '返品（1注文に複数可）';
COMMENT ON COLUMN returns.refund_amount IS '返金額（円）';
COMMENT ON COLUMN returns.id IS '主キー（uuidv7で自動採番）';
COMMENT ON COLUMN returns.order_id IS '対象注文（ordersへの参照。1注文に複数可）';
COMMENT ON COLUMN returns.reason IS '返品理由';
COMMENT ON COLUMN returns.status IS '状態（requestedは申請、approvedは承認、receivedは受領、refundedは返金済、rejectedは却下）';
COMMENT ON COLUMN returns.returned_at IS '返品受領日時（NULLは未受領）';
COMMENT ON COLUMN returns.created_at IS '申請日時';

CREATE TABLE reviews (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    user_id uuid NOT NULL REFERENCES users (id),
    product_id uuid NOT NULL REFERENCES products (id),
    rating integer NOT NULL CHECK (rating BETWEEN 1 AND 5),
    comment text,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (user_id, product_id)
);
COMMENT ON TABLE reviews IS 'レビュー（同一ユーザーの同一商品は1件）';
COMMENT ON COLUMN reviews.id IS '主キー（uuidv7で自動採番）';
COMMENT ON COLUMN reviews.user_id IS '投稿者（usersへの参照）';
COMMENT ON COLUMN reviews.product_id IS '対象商品（productsへの参照）';
COMMENT ON COLUMN reviews.rating IS '評価（1から5の5段階）';
COMMENT ON COLUMN reviews.comment IS '本文（NULL可）';
COMMENT ON COLUMN reviews.created_at IS '投稿日時';

-- ============ 行動ログ ============
-- 追記だけの表（UPDATE しない）。created_at の順に物理的に並ぶので、BRIN 索引が効く（第10章）。
CREATE TABLE behavior_logs (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    user_id uuid REFERENCES users (id),
    product_id uuid REFERENCES products (id),
    action varchar(30) NOT NULL
        CHECK (action IN ('view', 'add_to_cart', 'remove_from_cart', 'search', 'purchase')),
    search_keyword varchar(255),
    created_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE behavior_logs IS '行動ログ（分析用、追記型。未ログインは user_id NULL、検索は product_id NULL）';
COMMENT ON COLUMN behavior_logs.id IS '主キー（uuidv7で自動採番）';
COMMENT ON COLUMN behavior_logs.user_id IS '行動者（NULLは未ログイン。usersへの参照）';
COMMENT ON COLUMN behavior_logs.product_id IS '対象商品（NULLは商品に紐づかない検索など）';
COMMENT ON COLUMN behavior_logs.action IS '行動（viewは閲覧、add_to_cartはカゴ入れ、remove_from_cartはカゴから出す、searchは検索、purchaseは購入）';
COMMENT ON COLUMN behavior_logs.search_keyword IS '検索語（検索以外はNULL）';
COMMENT ON COLUMN behavior_logs.created_at IS '行動日時';

-- ============ updated_at トリガー（updated_at を持つ全表） ============
CREATE TRIGGER trg_users_updated_at BEFORE UPDATE ON users
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_addresses_updated_at BEFORE UPDATE ON addresses
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_sellers_updated_at BEFORE UPDATE ON sellers
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_products_updated_at BEFORE UPDATE ON products
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_inventory_updated_at BEFORE UPDATE ON inventory
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_orders_updated_at BEFORE UPDATE ON orders
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
