-- Instalar extensão pgvector (execute primeiro se ainda não tiver)
CREATE EXTENSION IF NOT EXISTS vector;

-- Criação da tabela para armazenar documentos com embeddings
CREATE TABLE public.documents_base (
    id BIGSERIAL PRIMARY KEY,
    content TEXT NOT NULL,
    metadata JSONB,
    embedding VECTOR(1536)  -- Ajuste a dimensão conforme necessário
);

-- Índices para melhorar performance
CREATE INDEX idx_documents_content ON public.documents_base USING gin(to_tsvector('portuguese', content));
CREATE INDEX idx_documents_metadata ON public.documents_base USING gin(metadata);
CREATE INDEX idx_documents_embedding ON public.documents_base USING ivfflat(embedding vector_cosine_ops) WITH (lists = 100);

-- Função para busca por similaridade de vetores
CREATE OR REPLACE FUNCTION match_documents (
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
LANGUAGE plpgsql
AS $
begin
  return query
  select
    d.id,
    d.content,
    d.metadata,
    1 - (d.embedding <=> query_embedding) as similarity
  from public.documents_base d
  where (filter = '{}'::jsonb or d.metadata @> filter)
    and (
      min_similarity <= 0
      or (1 - (d.embedding <=> query_embedding)) >= min_similarity
    )
  order by d.embedding <=> query_embedding
  limit match_count;
end;
$;
