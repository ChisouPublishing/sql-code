# Promptテンプレート集（第7章・付録D）

`codes/sql-code/prompts/templates.md@v1.2.2`。AIにSQLを設計させるときの再利用雛形。
AIの出力は必ず `queries/ch08_verify.sql` の手順で検証する。

## 基本形（日本語）

```
あなたはデータベース設計の専門家です。
以下の業務要件からPostgreSQL 18用のSQLを設計してください。

【テーブル構造】
（init/02_tables.sql の該当DDLを貼り付け）
（サンプル3行: SELECT * FROM <表> LIMIT 3; の結果）

【業務口径】
- 売上 = SUM(order_items.quantity * order_items.price)（税込・値引き前・送料を含まない）
- 顧客の支払額は orders.amount（請求額 = subtotal - discount_amount + shipping_fee）。売上と混同しない
- 除外: orders.status NOT IN ('cancelled', 'returned')
- 期間: ordered_at基準、JST、境界は >= / < の半開区間
- 集計粒度: （例: 日次・カテゴリ別）

【制約条件】
- 応答1秒以内、対象は過去30日
- 出力列: （例: category_name, total_sales, growth_pct）
- CTE・ウィンドウ関数・FILTER可、SELECT * 禁止

【出力】
1. SQL
2. 実行計画の予想（どこが重いか）
3. 自分のSQLの問題点（3つ自己批判）
4. 代替案（可読性・性能・保守性の観点）
```

## Basic template (English)

```
You are a database design expert.
Design SQL for PostgreSQL 18 from the requirements below.

[Schema]
(Paste the DDL from init/02_tables.sql)
(Sample 3 rows: result of SELECT * FROM <table> LIMIT 3;)

[Business definitions]
- Sales = SUM(order_items.quantity * order_items.price) (tax included, before coupon discount, excluding shipping)
- What the customer pays is orders.amount (= subtotal - discount_amount + shipping_fee). Do not mix it up with sales
- Exclude: orders.status NOT IN ('cancelled', 'returned')
- Period: ordered_at, JST, half-open interval with >= / <
- Grain: (e.g. daily by category)

[Constraints]
- Under 1 second, last 30 days
- Output columns: (e.g. category_name, total_sales, growth_pct)
- CTEs, window functions, FILTER allowed; SELECT * forbidden

[Output]
1. SQL
2. Expected plan (where is the bottleneck?)
3. Self-critique (3 weaknesses of your own SQL)
4. Alternative (readability / performance / maintainability)
```

## 段階誘導（Step1→Step3）

1. Step1: 使う表と列を列挙させる（JOIN・粒度はまだ書かせない）
2. Step2: JOIN条件と集計粒度だけ書かせる
3. Step3: SQL全文を書かせる（Step1–2と矛盾がないか人間が確認）

## 検証用（反例を探させる）

```
上のSQLが誤るケース（反例）を3つ挙げてください。
観点: NULL、0件、境界値（期間の端）、重複（fan-out）、
      ステータス除外漏れ、タイムゾーン。
各反例の検出クエリも書いてください。
```

## 境界ルール（DBと業務ロジックの分離・全テンプレ共通）

- DBは集計のみ。割引計算・ランク判定・状態遷移はアプリ層
- ストアドプロシージャの新規提案は禁止（init/04b_generators.sql の造数用を除く）
- 状態の日時（いつ払われた・いつ取り消された）は order_status_histories から引く（orders に日時列を足さない）
