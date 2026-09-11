create table if not exists catalog_versions (
  catalog_version text primary key,
  published_at timestamptz not null default now(),
  payload jsonb not null,
  active boolean not null default false
);

create unique index if not exists one_active_catalog_version
  on catalog_versions (active)
  where active;

create table if not exists catalog_disable_events (
  id bigserial primary key,
  catalog_version text not null,
  scope text not null check (scope in ('provider', 'intersection', 'approach')),
  key text not null,
  reason text not null,
  evidence text not null,
  created_at timestamptz not null default now()
);
