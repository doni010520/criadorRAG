-- 1) Extensão pgvector
create extension if not exists vector;

-- 2) Tabela de chunks para RAG
-- text-embedding-3-small = 1536 dimensões
-- se mudar de modelo, ajuste o (1536) abaixo
create table if not exists public.documents_liron (
  id           bigserial primary key,
  doc_id       text,                           -- id lógico do documento (arquivo) para você reagrupar/atualizar
  chunk_idx    integer,                        -- posição do chunk no documento
  content      text not null,                  -- texto do chunk
  metadata     jsonb not null default '{}'::jsonb, -- metadados livres (ex.: {"Arquivo": "Manual.pdf", "mimeType":"application/pdf"})
  embedding    vector(1536) not null,          -- vetor do chunk
  token_count  integer,                        -- opcional, útil para auditoria/custos
  embedding_model text default 'text-embedding-3-small',
  namespace    text default 'default',         -- útil p/ multi-cliente/coleções
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

-- Evite duplicidade por documento+chunk
alter table public.documents_liron
  add constraint documents_liron_doc_chunk_uniq unique (doc_id, chunk_idx);

-- 3) Índices para performance
-- índice vetorial (cosine). Ajuste lists conforme volume (100~200 é bom p/ iniciar).
create index if not exists documents_liron_embedding_ivfflat
  on public.documents_liron
  using ivfflat (embedding vector_cosine_ops)
  with (lists = 100);

-- consultas por metadados e por (doc_id, chunk_idx)
create index if not exists documents_liron_metadata_gin on public.documents_liron using gin (metadata);
create index if not exists documents_liron_doc_chunk_idx on public.documents_liron (doc_id, chunk_idx);

-- 4) Trigger simples para updated_at
create or replace function public.set_updated_at() returns trigger
language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end $$;

drop trigger if exists trg_documents_liron_updated_at on public.documents_liron;
create trigger trg_documents_liron_updated_at
before update on public.documents_liron
for each row execute function public.set_updated_at();

-- 5) Função RPC que o seu node chama (queryName = 'match_documents')
-- Filtrável por metadata e com limiar opcional de similaridade.
create or replace function public.match_documents(
  query_embedding vector(1536),
  match_count     int    default 5,
  filter          jsonb  default '{}'::jsonb,
  min_similarity  float  default 0
)
returns table (
  id         bigint,
  content    text,
  metadata   jsonb,
  similarity float,
  doc_id     text,
  chunk_idx  int
)
language plpgsql
as $$
begin
  return query
  select
    d.id,
    d.content,
    d.metadata,
    1 - (d.embedding <=> query_embedding) as similarity, -- cosine: 1 - distância
    d.doc_id,
    d.chunk_idx
  from public.documents_liron d
  where (filter = '{}'::jsonb or d.metadata @> filter)
    and (
      min_similarity <= 0
      or (1 - (d.embedding <=> query_embedding)) >= min_similarity
    )
  order by d.embedding <=> query_embedding
  limit match_count;
end;
$$;

-- 6) (Opcional) função de upsert para facilitar reindexação por documento+chunk
create or replace function public.upsert_document_chunk_liron(
  _doc_id      text,
  _chunk_idx   int,
  _content     text,
  _metadata    jsonb,
  _embedding   vector(1536),
  _model       text default 'text-embedding-3-small',
  _namespace   text default 'default',
  _token_count int  default null
) returns bigint
language plpgsql
as $$
declare
  v_id bigint;
begin
  insert into public.documents_liron (doc_id, chunk_idx, content, metadata, embedding, embedding_model, namespace, token_count)
  values (_doc_id, _chunk_idx, _content, _metadata, _embedding, _model, _namespace, _token_count)
  on conflict (doc_id, chunk_idx) do update
    set content        = excluded.content,
        metadata       = excluded.metadata,
        embedding      = excluded.embedding,
        embedding_model= excluded.embedding_model,
        namespace      = excluded.namespace,
        token_count    = excluded.token_count,
        updated_at     = now()
  returning id into v_id;
  return v_id;
end;
$$;

-- 7) (RLS) – se você NÃO vai consultar direto do front usando a role "anon/authenticated",
-- pode simplesmente deixar para o service_role do Supabase (que ignora RLS).
-- Caso queira ligar RLS mesmo assim e liberar tudo para service_role:
alter table public.documents_liron enable row level security;

-- política ampla (service_role ignora RLS, mas deixamos uma de exemplo para authenticated):
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'documents_liron' and policyname = 'read_documents_liron'
  ) then
    create policy read_documents_liron
      on public.documents_liron
      for select
      using (true);
  end if;
end $$;
