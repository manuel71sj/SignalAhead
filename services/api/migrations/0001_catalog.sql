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

-- Existing deployments use this same idempotent migration. Validate new writes
-- without trusting legacy payloads; runtime loading separately applies JSON Schema.
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'catalog_payload_identity' and conrelid = 'catalog_versions'::regclass
  ) then
    alter table catalog_versions add constraint catalog_payload_identity
      check (
        jsonb_typeof(payload) = 'object'
        and payload->>'kind' = 'ApproachCatalog'
        and payload->>'catalogVersion' = catalog_version
      ) not valid;
  end if;
  if not exists (
    select 1 from pg_constraint
    where conname = 'catalog_disable_version_fk' and conrelid = 'catalog_disable_events'::regclass
  ) then
    alter table catalog_disable_events add constraint catalog_disable_version_fk
      foreign key (catalog_version) references catalog_versions(catalog_version) not valid;
  end if;
end $$;

create index if not exists catalog_disable_events_version
  on catalog_disable_events (catalog_version, created_at);
