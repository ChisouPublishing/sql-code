# sql-code — 『AI時代のデータリテラシー』共通コアSQL v1.2.1

書籍（`books/ai-sql`）の全章で使う、再現可能なSQL一式。
コードはMIT、本文は All Rights Reserved（企画書 §9.3）。
変更履歴は `CHANGELOG.md`、実測の記録は `VALIDATION.md`。

## 2つのDB

| DB | 中身 | 使う章 | 作り方 |
| --- | --- | --- | --- |
| `sakura_market`（既定） | small＋medium（users 10万・orders 10万・order_items 約30万・behavior_logs 約100万） | 第4〜9章・第15章 | `make init-medium` |
| `sakura_xl`（性能比較用） | 同じスキーマに medium＋large＋xlarge（users 100万・orders 1000万・order_items 約3000万・behavior_logs 1000万） | 第10〜14章 | `make init-xlarge DB=sakura_xl` |

どちらも同じコンテナ（`sakura_market_db`）の中にある。`docker-compose.yml` が初回に作るのは `sakura_market` だけで、
`sakura_xl` は Makefile が `CREATE DATABASE` で作る。Makefile の対象DBは `DB=...` で切り替える（既定 `sakura_market`）。

## 本との対応（どこがどの章か）

| パス | 章 | 内容 |
| --- | --- | --- |
| `docker-compose.yml` | 第2章・付録B・第13章 | PostgreSQL 18（`io_method=worker` / slow-log 200ms）＋接続プール PgBouncer（profile `pool`） |
| `docker-compose.pgvector.yml` | 第15章 | pgvector差分上書き |
| `init/01_schema.sql` | 第2章 | `sakura` schema＋search_path（接続中のDBに設定） |
| `init/02_tables.sql` | 第4・5章 | 18テーブルDDL（PK=`uuidv7()`、金額の内訳、状態履歴、配送先の写し、updated_at トリガー） |
| `init/03_indexes.sql` | 第5章 | 基礎索引（子の外部キー列・代表列・部分索引） |
| `init/04_master_data.sql` | 第5章 | カテゴリ/販売者/クーポン/キャンペーン |
| `init/04b_generators.sql` | 第5章・付録C | 造数の共通手続き（`gen_users`・`gen_products`・`gen_orders`・`gen_behavior_logs`） |
| `init/05_small_data.sql` | 第5・6章 | 100行級・決定的（seed 0.42） |
| `init/06_medium_data.sql` | 第4〜9章 | 10万行級＋行動ログ100万行（`sakura_market` の完成形） |
| `init/07_large_data.sql` | 第10〜14章 | 行動ログを1000万行に作り直す（時刻順。`sakura_xl` 用） |
| `init/08_xlarge_data.sql` | 第10〜14章 | users 100万・products 10万・orders 1000万（`sakura_xl` 用） |
| `queries/ch01_ai_errors.sql` | 第1章 | 4大典型エラー＋3ケースの対比 |
| `queries/ch06_basic_10.sql` | 第6章 | 実業務10クエリ（売上口径統一） |
| `queries/ch07_ai_design_3cases.sql` | 第7章 | 同一要件3案（A・B・C誤り例・C'修正版） |
| `queries/ch08_verify.sql` | 第8章 | 試し実行（試運行）4段階・検証・防御・権限（ROLLBACKで残さない） |
| `queries/ch09_explain_5.sql` | 第9章 | 遅い5クエリ＋改善 |
| `queries/ch10_index_design.sql` | 第10章 | 種類・複合・INCLUDE・部分・スキップスキャン・重複/未使用検出（`sakura_xl`） |
| `queries/ch11_monitoring.sql` | 第11章 | pg_stat_statements活用・スナップショット・pgBadger |
| `queries/ch12_tuning.sql` | 第12章 | 書き換え・パラメータ・パーティション・マテビュー・完全ケース（`sakura_xl`） |
| `queries/ch14_dashboard.sql` | 第14章 | リアルタイム売上ダッシュボード一式（`sakura_xl`） |
| `queries/ch15_pgvector.sql` | 第15章 | pgvector・RAGデータ層・ハイブリッド検索（pgvectorイメージ用） |
| `queries/ch15_governance.sql` | 第15章 | ガバナンス・列権限・RLS・監査（ROLLBACKで残さない） |
| `bench/sakura_bench.sql` | 第13章 | pgbenchカスタム（購買フロー・読み取り） |
| `bench/dashboard_bench.sql` | 第14章 | pgbenchカスタム（ダッシュボード参照） |
| `checks/verify_all.sql` | 第5・8章 | 行数・FK・索引のないFK・日付・業務ルール・金額照合・状態履歴・偏り・容量 |
| `prompts/templates.md` | 第7章・付録D | Promptテンプレート（日英） |

## 業務ルール（全章共通・変更時は minor を上げる）

Sakura Market は、会員が商品を注文し、決済・発送・配達・（ときに）返品が続くECサイト。

**売上などの口径**

- 売上（商品売上）= `SUM(order_items.quantity * order_items.price)`（税込、注文時の単価。クーポン値引き前、送料を含まない）
- 顧客が払う額は `orders.amount`（請求額）= `subtotal`（小計＝明細の合計）- `discount_amount`（クーポン値引き）+ `shipping_fee`（送料）。売上と混同しない
- 除外 = `orders.status NOT IN ('cancelled','returned')`（取消・返品の注文は売上に入れない）
- 期間は `ordered_at`（注文日時）の時刻範囲で判定する。日付の境界は日本時間（Asia/Tokyo）、`>= / <` の半開区間。
  列を関数で包まない（`ordered_at::date = ...` ではなく `ordered_at >= 開始 AND ordered_at < 終了`。索引が効き、TimeZone 設定にも左右されない）
- 顧客数のような「重複を除く数」は日ごとに足さない（期間で `count(DISTINCT ...)` する）
- 論理削除行は `deleted_at IS NULL` で除外、`rank` は小文字（bronze/silver/gold/platinum）

**注文の流れと記録**

| 出来事 | orders.status | 残る記録 |
| --- | --- | --- |
| 注文受付 | `ordered` | orders・order_items・状態履歴（from NULL → ordered） |
| 決済（カード・PayPalは数分、コンビニ払いは1〜72時間） | `paid` | payments（決済額 = 請求額）・状態履歴 |
| 発送（決済の6〜48時間後） | `shipped` | shipments（配送先は既定住所の写し）・状態履歴 |
| 配達（発送の18〜72時間後） | `delivered` | shipments.delivered_at・状態履歴 |
| 取消（受付の1〜72時間後。決済前ならコンビニ払いの期限切れ） | `cancelled` | 状態履歴（いつ取り消したか）。決済は前なら failed、後なら refunded |
| 返品（配達の2〜10日後） | `returned` | returns（返金額。お客様都合は送料を返さない）・payments は refunded |

- 「いつ取り消されたか」「いつ払われたか」は `order_status_histories` の `changed_at` で答える（orders は今の状態だけを持つ）
- 送料は小計5000円未満なら500円、以上は無料。クーポンは最低小計を満たし、使用回数の上限（`max_uses`、NULL は上限なし）の範囲で使える
- `coupons.used_count` = 取り消されていない注文での使用回数
- 既定の届け先住所は1人1件。同じ注文に同じ商品は1行（数量でまとめる）。同じカテゴリ名は同じ親の下に1つ

## 動作環境：Docker Desktop 標準 / OrbStack 可（第2章）

Windows対応のため標準は **Docker Desktop**。macOSでは軽量なOrbStackでもよい。
`docker compose` が動けばどちらでも手順は同じ。

| | Docker Desktop（標準） | OrbStack（macOSのみ・代替） |
| --- | --- | --- |
| インストール | [docker.com](https://www.docker.com/products/docker-desktop/) からDocker.app / WindowsはDocker Desktop for Windows（WSL 2必要） | `brew install --cask orbstack`（または公式アプリ） |
| 起動 | Docker.appを起動 | OrbStack.appを起動（軽量・常駐可） |
| 切替確認 | `docker context ls` | `docker context use orbstack` / `desktop-linux` |
| 本書の起動 | `docker compose up -d` | 同じ（`docker compose` 互換） |
| ログ | `docker compose logs postgres` | 同じ |
| 停止・削除 | `docker compose down` | 同じ |

基本コマンド（どちらも共通）：

```bash
docker context ls            # 今どのランタイムか確認（* が有効）
docker context use orbstack  # OrbStackを使う場合
docker images postgres       # イメージ確認（なければ自動取得）
docker compose up -d         # 起動
docker compose ps            # 状態確認
docker compose logs postgres # ログ（slow-logの duration: 行もここ）
docker compose down          # 停止（コンテナを消す。データは ./pgdata に残る）
```

`io_method`（PG18の非同期I/O）は `worker` にしてある。`io_uring` は Linux カーネルの機能で、
macOS 上の Docker Desktop / OrbStack では使えない。Linux サーバーで試すときだけ
`docker-compose.yml` の `io_method=worker` を `io_uring` に変える（第12章 §06）。

原稿から参照するときはバージョン付きで書く：例 `codes/sql-code/queries/ch06_basic_10.sql@v1.2.2`。

## 再現手順（最短）

```bash
cd codes/sql-code
make up            # PostgreSQL 18 起動（初回はimage取得）
make init-medium   # schema〜small〜medium を sakura_market に投入（約30秒）
make verify        # 整合性チェック（最後の summary が ALL OK になること）
```

性能比較用DB（時間と容量がかかる。実測は `VALIDATION.md`）：

```bash
make init-xlarge DB=sakura_xl   # small→medium→large→xlarge を sakura_xl に投入（目安 20〜30分・約20GB）
make verify DB=sakura_xl        # 数分かかる
make bench-init DB=sakura_xl    # 第13章の pgbench 標準表（pgbench_*、scale 10）
```

最初から作り直す（データも消す）：

```bash
make reset         # = docker compose down ＋ rm -rf pgdata
make init-medium
```

`./pgdata` はバインドマウント（ホストのフォルダ）なので、`docker compose down -v` では消えない。
消すには `rm -rf pgdata`（`make reset`）が要る。中身はすべて init スクリプトで作り直せる。

接続：

```bash
docker exec -it sakura_market_db psql -U sakura -d sakura_market
docker exec -it sakura_market_db psql -U sakura -d sakura_xl
```

DBeaver： host `localhost` / port `5432` / db `sakura_market`（または `sakura_xl`）/ user `sakura` / pass `sakura_dev`。

## pgbench（第13・14章）

ホストにPostgreSQLクライアントが無くても動くよう、pgbenchはコンテナで実行する：

```bash
make bench-smoke             # sakura_bench.sql を -c 2 -j 1 -t 10（既定DB）
make bench-smoke DB=sakura_xl
```

等価な手動実行（カスタムスクリプトは `-n` を付ける。pgbench_* 表の VACUUM を省く）：

```bash
docker run --rm --network sql-code_default -e PGPASSWORD=sakura_dev \
  -v "$PWD/bench:/bench:ro" postgres:18 \
  pgbench -n -c 10 -j 2 -T 60 -f /bench/sakura_bench.sql \
  -U sakura -d sakura_xl -h sakura_market_db
# ダッシュボード参照（ch14実行済み前提）
docker run --rm --network sql-code_default -e PGPASSWORD=sakura_dev \
  -v "$PWD/bench:/bench:ro" postgres:18 \
  pgbench -n -c 50 -j 8 -T 300 -f /bench/dashboard_bench.sql \
  -U sakura -d sakura_xl -h sakura_market_db
```

標準スクリプトの初期化（scale 10 = accounts 100万行）は `make bench-init DB=sakura_xl`。

## 接続プール PgBouncer（第13章）

アプリが要求のたびに接続を作り直すと、接続を作る時間（約1ms）が毎回かかり、
`max_connections`（既定100）を超える同時接続はエラーになる。接続プールは、少ないサーバー接続を使い回す。

```bash
make pool-up      # = docker compose --profile pool up -d pgbouncer（ポート6432）
# コンテナの pgbench から: -h sakura_pgbouncer -p 5432 / ホストから: -h localhost -p 6432
make pool-down
```

- イメージは `edoburu/pgbouncer:v1.26.0-p0`（PgBouncer 1.26.0）に固定
- `pool_mode=transaction`（トランザクションの間だけサーバー接続を貸す）、`default_pool_size=20`、`max_client_conn=1000`
- 開発用の設定：認証は平文パスワード（`AUTH_TYPE=plain`、compose に直書き）。本番では `scram-sha-256` と `auth_query`、TLS を使う
- transaction モードでは、`SET`・一時表・SQLの `PREPARE`・セッション単位のアドバイザリロックが次のトランザクションに持ち越されない
  （同じサーバー接続に戻る保証がない）。トランザクションの中で完結させるか、`SET LOCAL` を使う
- 実測（直結・毎回接続・PgBouncer経由、`-c 150` で `max_connections` 超え）は `VALIDATION.md` §7

## 監視画面 pgAdmin 4（第11・13・14章「画面で確かめる」）

ダッシュボード（接続数・TPS・読んだ行・Block I/O のグラフ）、実行中の接続と待ち（State）、
Query Tool（`pg_stat_statements` の差分、`EXPLAIN ANALYZE` のグラフィカル表示）を画面で見る。ローカル専用。

```bash
make monitor-up     # = docker compose --profile monitor up -d pgadmin（初回はイメージ取得、約1分で起動）
open http://localhost:5050   # ログイン画面なし。左の Sakura Market の下に2つのサーバーが登録済み
make monitor-down
```

- イメージは `dpage/pgadmin4:9.18` に固定。ポートは `127.0.0.1:5050`（このマシンからだけ開ける）
- サーバー登録は `pgadmin/servers.json` で自動：`sakura_market（small＋medium）` と `sakura_xl（性能比較用）`（どちらも compose の `postgres`）。
  パスワードは `pgadmin/pgpass`（起動時にコンテナの中へ写して 600 にする）
- 開発用の設定：デスクトップモード（`PGADMIN_CONFIG_SERVER_MODE=False`、マスターパスワードなし）、
  資格情報 `admin@example.com` / `sakura_dev`。外部に公開するマシンでは使わない
- グラフの更新は既定で5秒ごとで、値は「5秒間の増分」になる。1秒あたりで読むには
  File → Preferences → Dashboards → Refresh rates を 1 にする（第11章 §08）
- 見る順：DB（sakura_xl）を選んで Dashboard → Activity（全体）→ State（待ち・ロック）→ Query Tool（上位の文・計画）
- 撮影の手順と証跡：`tools/`（Playwright で画面を撮り、`*.marks.json` から赤枠・拡大図を描く）、`evidence/<日時>_<作業>/`

## pgvector（第15章のみ）

本書のDB（`postgres:18`）には vector 拡張が無い。pgvector入りのイメージで、別の一時コンテナを立てて試す
（名前・ポート・ボリュームを本書のDBと別にする。共有のDBを止めない）。`codes/sql-code` のフォルダで実行する。

```bash
docker run -d --name sakura_pgvector_tmp \
  -e POSTGRES_USER=sakura -e POSTGRES_PASSWORD=sakura_dev -e POSTGRES_DB=sakura_market \
  -e TZ=Asia/Tokyo -e PGTZ=Asia/Tokyo \
  -p 55432:5432 -v sakura_pgvector_tmp_data:/var/lib/postgresql \
  pgvector/pgvector:pg18 postgres -c io_method=worker
for f in init/01_schema.sql init/02_tables.sql init/03_indexes.sql \
         init/04_master_data.sql init/04b_generators.sql init/05_small_data.sql; do
  docker exec -i sakura_pgvector_tmp psql -U sakura -d sakura_market -v ON_ERROR_STOP=1 -q < "$f"
done
docker exec -i sakura_pgvector_tmp psql -U sakura -d sakura_market < queries/ch15_pgvector.sql
```

- 起動の直後は初期化の途中で `database "sakura_market" does not exist` が出ることがある。数秒待ってから `for` の行を流す
- 一時コンテナ: 名前 `sakura_pgvector_tmp`・ポート 55432・ボリューム `sakura_pgvector_tmp_data`（本書のDBは `sakura_market_db`・5432・`./pgdata`）
- 試し終わったら消す（本書のDBには影響しない）:

```bash
docker rm -f sakura_pgvector_tmp
docker volume rm sakura_pgvector_tmp_data
```

自分専用の環境なら、本書のDBのイメージを差し替えてもよい（コンテナが作り直される。データは `./pgdata` に残る）:
`docker compose -f docker-compose.yml -f docker-compose.pgvector.yml up -d`

## トラブルシューティング（第2章 §2.8）

| 症状 | 対処 |
| --- | --- |
| `port is already allocated` | 既存PG停止 or composeの `"5432:5432"` を `"5433:5432"` に変更 |
| `io_uring` で起動失敗 | `command` の `io_method` を `worker` に戻して再起動（macOS/旧kernel） |
| `connection refused` | `docker compose logs postgres` で確認、初回は初期化完了まで待つ |
| `relation "users" already exists` | 投入済みのDBにもう一度 init を流した。`make reset` してから投入する（`sakura_xl` だけなら `DROP DATABASE sakura_xl`） |
| xlarge が遅い/容量不足 | `df -h` で空きを見る。medium までで止めるか、`08_xlarge_data.sql` を途中で止めて再実行（足りない分だけ作る） |

## 検証済み

- `make reset && make init-medium && make verify`、`make init-xlarge DB=sakura_xl && make verify DB=sakura_xl` を
  Docker（postgres:18）で実行し、checks がすべて OK になることを確認（VALIDATION.md 参照）。

## CSVとアプリ側SQLの最小実習

日本語版第5・7・8章で使う追加実習。既存データの再初期化は不要です。

- `examples/csv/input.csv` → `queries/ch05_csv_roundtrip.sql`：コンテナの`/tmp/ai-sql-csv-input.csv`へ入力をコピーしてpsqlで実行。一時表で検査し、`/tmp/ai-sql-csv-output.csv`へ書き出します。
- `queries/ch07_llm_material.sql`：教材の合成データの状態別件数。外部LLMへの自動送信はしません。
- `examples/ch08_parameter_binding.py`：Psycopg 3をインストールし、環境変数`SAKURA_DSN`を設定して実行。一時表の検索を文字列結合とパラメータ化で比較します。

実行手順と掲載コードは日本語版第5・7・8章、実DBの記録は`evidence/20261012_ebook_readability/`にあります。
