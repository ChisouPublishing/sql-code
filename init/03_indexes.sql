-- 03_indexes.sql — 基礎索引（第5章 §5.4）
-- codes/sql-code/init/03_indexes.sql@v1.2.2
-- 方針: 参照する側（子）の外部キー列と、代表的な検索列にB-tree。論理削除テーブルは部分索引。
-- 高度な索引（複合・INCLUDE・GIN/BRIN）は queries/ch10_index_design.sql で扱う。
--
-- v1.2.0 の見直し（第5章の洗い出しで「索引なし」だった外部キー7本）
--   * 張った: shipments.address_id / orders.coupon_id / returns.order_id /
--             inventory_logs.product_id / addresses.user_id / campaign_coupons.coupon_id
--     どれも「親を消す・直すときに子を探す」「子を親から引く」場面がある（例: 注文から返品を引く）。
--   * 代用: categories.parent_id は一意制約 uq_categories_parent_name (parent_id, name) の先頭列で足りる
--   * 削除: idx_order_items_order は、一意制約 uq_order_items_order_product (order_id, product_id)
--     の先頭列と重複するので作らない（同じ働きの索引が2本あると、書き込みが遅くなるだけ）
-- 確認: 第5章の洗い出しクエリで「索引のない外部キー列」が0本になる。

SET search_path TO sakura, public;

-- 商品
CREATE INDEX IF NOT EXISTS idx_products_category ON products (category_id);
CREATE INDEX IF NOT EXISTS idx_products_seller ON products (seller_id);

-- 注文
CREATE INDEX IF NOT EXISTS idx_orders_user ON orders (user_id);
CREATE INDEX IF NOT EXISTS idx_orders_ordered_at ON orders (ordered_at);
CREATE INDEX IF NOT EXISTS idx_orders_coupon ON orders (coupon_id);
-- order_items(order_id) は uq_order_items_order_product が兼ねる
CREATE INDEX IF NOT EXISTS idx_order_items_product ON order_items (product_id);
-- 状態履歴: 「この注文の履歴を時刻順に」を1本で引く
CREATE INDEX IF NOT EXISTS idx_order_status_histories_order
    ON order_status_histories (order_id, changed_at);
CREATE INDEX IF NOT EXISTS idx_returns_order ON returns (order_id);
CREATE INDEX IF NOT EXISTS idx_shipments_address ON shipments (address_id);

-- 顧客・在庫・販促
CREATE INDEX IF NOT EXISTS idx_addresses_user ON addresses (user_id);
CREATE INDEX IF NOT EXISTS idx_inventory_logs_product ON inventory_logs (product_id, created_at);
CREATE INDEX IF NOT EXISTS idx_campaign_coupons_coupon ON campaign_coupons (coupon_id);

-- 行動ログ・レビュー
CREATE INDEX IF NOT EXISTS idx_behavior_logs_user_time ON behavior_logs (user_id, created_at);
CREATE INDEX IF NOT EXISTS idx_behavior_logs_product_time ON behavior_logs (product_id, created_at);
CREATE INDEX IF NOT EXISTS idx_reviews_product ON reviews (product_id);
-- reviews(user_id) は一意制約 (user_id, product_id) の先頭列で足りる

-- 論理削除テーブル: 有効行だけの部分索引
CREATE INDEX IF NOT EXISTS idx_users_active ON users (email) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_products_active ON products (sku) WHERE deleted_at IS NULL;
