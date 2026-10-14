-- 05_small_data.sql — 小規模データ100行級（第5章 §5.7、第6章の動作確認用）
-- codes/sql-code/init/05_small_data.sql@v1.2.2
-- 前提: 01〜04・04b_generators.sql 投入済み。
-- 方針: 再現可能（SELECT setseed(0.42) のあと、共通手続き gen_* を呼ぶ）。
--       作り直すと、会員・商品は id と時刻を除いて同じ内容になる（注文は投入時刻で内訳が少し変わる）。
-- 到達規模（実測 v1.2.0）: users 100 / addresses 約120 / products 100 / orders 50 /
--   order_items 約100 / 状態履歴 約190 / payments 約50 / shipments 約45 / behavior_logs 200。
-- 業務ルール（状態の決まり方・金額の内訳・クーポン・送料など）は 04b_generators.sql の冒頭を参照。

SET search_path TO sakura, public;
SELECT setseed(0.42) \gset

-- 会員100人（登録日は過去365日に散らす。ランク: platinum 1 / gold 5 / silver 20 / bronze 74）
CALL sakura.gen_users('user_', 'ユーザー', 100, 365);

-- 商品100品（SKU-0001〜SKU-0100）と在庫
CALL sakura.gen_products('SKU-', '商品', 4, 100);

-- 注文50件（明細1〜3行）。小規模でも NULL や取消が見えるよう、
-- クーポンは3割の注文で試し、レビューは配達済みの半分に付ける
--   45件: 過去90日（ほとんどが配達済みになる）
--    5件: 直近1日（未決済 ordered・決済済 paid・発送済 shipped が残る）
CALL sakura.gen_orders(45, 90, 3, 100000, 0.5, 0.3);
CALL sakura.gen_orders(5, 1, 3, 100000, 0.5, 0.3);

-- 行動ログ200件（過去30日、時刻順）
CALL sakura.gen_behavior_logs(200, 30);

-- 統計情報（小さい表は自動ANALYZEの閾値に届かないので、明示的に全表）
ANALYZE;
