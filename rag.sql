-- Instalar extensão pgvector (execute primeiro se ainda não tiver)
CREATE EXTENSION IF NOT EXISTS vector;

-- Tabela de documentos
CREATE TABLE IF NOT EXISTS public.documents_base (
    id BIGSERIAL PRIMARY KEY,
    content  TEXT   NOT NULL,
    metadata JSONB,
    embedding VECTOR(1536)  -- ajuste a dimensão conforme o seu modelo
);

-- Índices
CREATE INDEX IF NOT EXISTS idx_documents_content
  ON public.documents_base USING gin (to_tsvector('portuguese', content));

CREATE INDEX IF NOT EXISTS idx_documents_metadata
  ON public.documents_base USING gin (metadata);

-- Para ivfflat, crie o índice depois de inserir uma quantidade razoável de linhas
CREATE INDEX IF NOT EXISTS idx_documents_embedding
  ON public.documents_base USING ivfflat (embedding vector_cosine_ops)
  WITH (lists = 100);

-- Função de similaridade (simples, em SQL)
CREATE OR REPLACE FUNCTION match_documents(
  query_embedding vector(1536),
  match_count integer,
  filter jsonb DEFAULT '{}'::jsonb,
  min_similarity double precision DEFAULT 0
)
RETURNS TABLE (
  id bigint,
  content text,
  metadata jsonb,
  similarity double precision
)
LANGUAGE SQL
AS $$
  SELECT
    d.id,
    d.content,
    d.metadata,
    1 - (d.embedding <=> query_embedding)::double precision AS similarity
  FROM public.documents_base AS d
  WHERE (filter = '{}'::jsonb OR d.metadata @> filter)
    AND (
      min_similarity <= 0
      OR (1 - (d.embedding <=> query_embedding)::double precision) >= min_similarity
    )
  ORDER BY d.embedding <=> query_embedding
  LIMIT match_count;
$$;
