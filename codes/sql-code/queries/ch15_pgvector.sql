-- ch15_pgvector.sql — pgvector入門＋RAGデータ層（第15章 §15.1–15.2）
-- codes/sql-code/queries/ch15_pgvector.sql@v1.2.2
-- 前提: docker-compose.pgvector.yml で起動（pgvector/pgvector:pg18）。init-small 以上を投入済み。
-- 本書の実寸は vector(1536)。ここでは軽量デモ vector(3) で実際に動かし、実用定義を併記する。
-- 何度流してもよい（自然キーの ON CONFLICT で重複を作らない）。

-- 拡張の有無を確認
SELECT name, default_version, installed_version
FROM pg_available_extensions WHERE name = 'vector';

CREATE EXTENSION IF NOT EXISTS vector;

SET search_path TO sakura, public;

-- ===== デモ: 類似検索 =====
-- name を自然キーにする（serial の id だけだと ON CONFLICT が働かず、再実行で行が増える）
CREATE TABLE IF NOT EXISTS items (
    id serial PRIMARY KEY,
    name text NOT NULL UNIQUE,
    embedding vector(3)
);
INSERT INTO items (name, embedding) VALUES
    ('a', '[1,2,3]'), ('b', '[1,2,4]'), ('c', '[4,5,6]'), ('d', '[1,0,0]')
ON CONFLICT (name) DO NOTHING;

-- L2(<->)・内積(<#>)・コサイン(<=>、テキスト推奨)
SELECT name, embedding <=> '[1,2,3]' AS distance
FROM items ORDER BY embedding <=> '[1,2,3]' LIMIT 5;

-- ===== 実用: products/reviewsにembedding列 =====
ALTER TABLE products ADD COLUMN IF NOT EXISTS embedding vector(1536);
ALTER TABLE reviews ADD COLUMN IF NOT EXISTS embedding vector(1536);

-- カテゴリ絞り＋類似（electronicsの類似商品TOP10の形）
-- SELECT p.sku, p.name_ja
-- FROM products p JOIN categories c ON p.category_id = c.id
-- WHERE c.name = 'electronics' AND p.deleted_at IS NULL
-- ORDER BY p.embedding <=> '[...query vector...]' LIMIT 10;

-- 索引: HNSW推奨（本番・高速・メモリ多）
-- CREATE INDEX ON products USING hnsw (embedding vector_cosine_ops);
-- 学習・大規模向け: CREATE INDEX ON products USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100);

-- ===== RAGデータ層（実用の定義） =====
CREATE TABLE IF NOT EXISTS documents (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    title varchar(255) NOT NULL,
    content text NOT NULL,
    source varchar(255) NOT NULL UNIQUE,     -- 出どころ（URL・ファイル名）を自然キーにする
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS chunks (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    document_id uuid NOT NULL REFERENCES documents (id) ON DELETE CASCADE,
    chunk_index int NOT NULL,
    content text NOT NULL,
    embedding vector(1536),
    metadata jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (document_id, chunk_index)        -- 同じ文書の同じ番号の断片は1行
);
-- (document_id, chunk_index) の一意制約が document_id の索引を兼ねる
-- CREATE INDEX ON chunks USING hnsw (embedding vector_cosine_ops);
-- 全文索引（ハイブリッド検索用）。PostgreSQL 標準の全文検索は日本語を単語に分けられない。
-- 日本語の文書なら pg_bigm / PGroonga などの拡張を使う。ここでは英語の文書を前提に 'english'
CREATE INDEX IF NOT EXISTS idx_chunks_fts
    ON chunks USING gin (to_tsvector('english', content));

-- ===== ハイブリッド検索（ベクトル＋全文のRRF融合）を小さなデータで動かす =====
-- 3次元のデモ表（実用は vector(1536) の chunks で同じSQL）
CREATE TABLE IF NOT EXISTS chunks_demo (
    id serial PRIMARY KEY,
    source text NOT NULL UNIQUE,
    content text NOT NULL,
    embedding vector(3) NOT NULL
);
INSERT INTO chunks_demo (source, content, embedding) VALUES
    ('faq-01', 'Return policy: items can be returned within 30 days. Return shipping is free for defects.', '[0.9,0.1,0.0]'),
    ('faq-02', 'Shipping fee is 500 yen for orders under 5000 yen.',                                 '[0.7,0.3,0.1]'),
    ('faq-03', 'Coupons cannot be combined. One coupon per order.',                                 '[0.1,0.9,0.1]'),
    ('faq-04', 'Convenience store payment must be completed within 72 hours.',                      '[0.0,0.2,0.9]'),
    ('faq-05', 'Refunds for returned items are issued to the original payment method.',             '[0.8,0.2,0.2]')
ON CONFLICT (source) DO NOTHING;

-- 問い合わせ「return shipping」（ベクトルは外部の埋め込みモデルで作る想定。ここでは [1,0.2,0]）
WITH vector_results AS (
    -- ベクトル側も上位k件（ここでは3件）に絞ってから順位を付ける。全件に順位を付けない
    SELECT id, ROW_NUMBER() OVER (ORDER BY embedding <=> '[1,0.2,0]') AS rnk
    FROM (SELECT id, embedding FROM chunks_demo
          ORDER BY embedding <=> '[1,0.2,0]' LIMIT 3) AS v
),
text_results AS (
    -- ts_rank は「大きいほど関連が強い」ので降順で順位を付ける
    SELECT id, ROW_NUMBER() OVER (
               ORDER BY ts_rank(to_tsvector('english', content),
                                plainto_tsquery('english', 'return shipping')) DESC) AS rnk
    FROM chunks_demo
    WHERE to_tsvector('english', content) @@ plainto_tsquery('english', 'return shipping')
)
SELECT c.source, left(c.content, 50) AS content,
       v.rnk AS vector_rank, t.rnk AS text_rank,
       round((COALESCE(1.0 / (60 + v.rnk), 0) + COALESCE(1.0 / (60 + t.rnk), 0))::numeric, 5) AS rrf
FROM vector_results v
FULL OUTER JOIN text_results t ON v.id = t.id
JOIN chunks_demo c ON c.id = COALESCE(v.id, t.id)
ORDER BY rrf DESC
LIMIT 10;

-- 更新（埋め込みは外部で再生成して入れ替え。文書単位でまとめて差し替える）
-- BEGIN;
-- DELETE FROM chunks WHERE document_id = (SELECT id FROM documents WHERE source = '...');
-- INSERT INTO chunks (document_id, chunk_index, content, embedding) VALUES (...);
-- COMMIT;
