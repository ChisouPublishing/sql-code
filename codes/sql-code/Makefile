# Makefile — codes/sql-code v1.2.2
# DB を切り替えて使う: 既定は sakura_market（small＋medium、第4〜9章・第15章）。
#   性能比較用（第10〜14章）: make init-xlarge DB=sakura_xl
DB ?= sakura_market
CONTAINER := sakura_market_db
PSQL = docker exec -i $(CONTAINER) psql -U sakura -d $(DB) -v ON_ERROR_STOP=1 -q
# ホストのSQLを標準入力で流す（./initはコンテナにマウントしない）
RUNSQL = $(PSQL) <
# pgbench はコンテナで動かす（ホストにPostgreSQLクライアントが無くてよい）
PGBENCH = docker run --rm --network sql-code_default -e PGPASSWORD=sakura_dev \
	-v "$(PWD)/bench:/bench:ro" postgres:18 pgbench -U sakura -h $(CONTAINER)

.PHONY: up down reset logs ps db init-small init-medium init-large init-xlarge verify \
	bench-smoke bench-init pool-up pool-down monitor-up monitor-down

up:
	docker compose up -d
	for i in 1 2 3 4 5 6 7 8 9 10 11 12; do \
	  docker exec $(CONTAINER) pg_isready -U sakura -d sakura_market > /dev/null 2>&1 && break; \
	  sleep 5; \
	done
	docker exec $(CONTAINER) pg_isready -U sakura -d sakura_market

# コンテナを止めて消す。データ（./pgdata はバインドマウント）は消えない
down:
	docker compose --profile pool --profile monitor down

# データも消して空にする（./pgdata を削除。次の make up で初期化からやり直し）
reset: down
	rm -rf pgdata

logs:
	docker compose logs postgres | tail -n 100

ps:
	docker compose ps

# DB が無ければ作る（sakura_market は compose が初回に作る。sakura_xl はここで作る）
db: up
	docker exec -i $(CONTAINER) psql -U sakura -d sakura_market -tAc \
	  "SELECT 1 FROM pg_database WHERE datname = '$(DB)'" | grep -q 1 || \
	  docker exec -i $(CONTAINER) psql -U sakura -d sakura_market -c 'CREATE DATABASE "$(DB)"'

init-small: db
	$(RUNSQL) init/01_schema.sql
	$(RUNSQL) init/02_tables.sql
	$(RUNSQL) init/03_indexes.sql
	$(RUNSQL) init/04_master_data.sql
	$(RUNSQL) init/04b_generators.sql
	$(RUNSQL) init/05_small_data.sql

init-medium: init-small
	$(RUNSQL) init/06_medium_data.sql

init-large: init-medium
	$(RUNSQL) init/07_large_data.sql

init-xlarge: init-large
	$(RUNSQL) init/08_xlarge_data.sql

verify:
	$(RUNSQL) checks/verify_all.sql

# カスタムスクリプトは -n（pgbench_* 表の VACUUM をしない。表が無いDBでも動く）
bench-smoke:
	$(PGBENCH) -n -c 2 -j 1 -t 10 -f /bench/sakura_bench.sql -d $(DB)

# 第13章: 標準スクリプト用の表（pgbench_*。scale 10 = accounts 100万行）。性能比較用DBに作る
bench-init:
	$(PGBENCH) -i -s 10 -d $(DB)

# 接続プール（PgBouncer、ポート6432）。第13章
pool-up:
	docker compose --profile pool up -d pgbouncer

pool-down:
	docker compose --profile pool stop pgbouncer

# 監視画面 pgAdmin 4（http://localhost:5050、ポート5050）。第11・13・14章「画面で確かめる」
monitor-up:
	docker compose --profile monitor up -d pgadmin

monitor-down:
	docker compose --profile monitor stop pgadmin
