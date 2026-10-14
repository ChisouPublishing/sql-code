"""第8章：文字列結合とパラメータ化を一時表で比較する。"""
# codes/sql-code/examples/ch08_parameter_binding.py@v1.2.2
import os
import psycopg

with psycopg.connect(os.environ['SAKURA_DSN']) as conn:
    with conn.cursor() as cur:
        cur.execute('CREATE TEMP TABLE binding_demo (name text PRIMARY KEY)')
        cur.executemany(
            'INSERT INTO binding_demo (name) VALUES (%s)',
            [('桜',), ("Tom's Shop",), ('梅',)],
        )
        # SQLの構造を変えようとする値を、隔離した一時表だけで試す。
        value = "' OR TRUE --"
        unsafe_sql = "SELECT name FROM binding_demo WHERE name = '" + value + "'"
        cur.execute(unsafe_sql)
        print('文字列結合:', len(cur.fetchall()))
        cur.execute('SELECT name FROM binding_demo WHERE name = %s', (value,))
        print('パラメータ化:', len(cur.fetchall()))
        cur.execute('SELECT name FROM binding_demo WHERE name = %s', ("Tom's Shop",))
        print('引用符を含む名前:', cur.fetchone()[0])
        # ORDER BYなどの識別子は値のプレースホルダーに渡さない。
        choices = {'名前順': 'name'}
        sort_column = choices['名前順']
        query = psycopg.sql.SQL('SELECT name FROM binding_demo ORDER BY {}').format(
            psycopg.sql.Identifier(sort_column)
        )
        cur.execute(query)
        print('許可した列による並べ替え:', len(cur.fetchall()))
    conn.rollback()
