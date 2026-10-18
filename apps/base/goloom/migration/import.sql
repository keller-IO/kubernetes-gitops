-- Einmal-Migration SQLite -> Postgres (Goloom v0.3.0): Daten aus _imp in die
-- Goloom-Tabellen. Spalten werden ueber den Namen zugeordnet und explizit auf
-- den Postgres-Typ gecastet (SQLite liefert Text/Integer: 0/1 -> boolean,
-- RFC3339 -> timestamptz, JSON-Text -> jsonb, JSON-Array-Text -> text[]).
-- Reihenfolge = Fremdschluessel (aus postgres-schema.sql abgeleitet).
-- Jede Abweichung (Tabelle oder Spalte ohne Ziel, Zeilenzahl) bricht ab.
create temp table _rename (tname text, src text, dst text) on commit drop;
insert into _rename values ('provider_instances', 'scopes_json', 'scopes');

do $$
declare
  tbls text[] := array[
    'users','teams','team_invitations','team_memberships','api_tokens','provider_instances',
    'social_accounts','post_templates','rss_feed_configs','scheduled_posts','scheduled_post_targets',
    'post_metrics','post_metrics_history','post_hashtags','account_metrics','account_metrics_history',
    'post_versions','team_profiles','campaign_formats','style_examples','knowledge_sources','ai_jobs',
    'ai_service_configs','proactive_trigger_settings','media_items','media_provider_mappings',
    'post_template_skips','log_entries','audit_events','job_locks','external_post_monitor_settings',
    'rss_imported_items','push_subscriptions','team_notification_prefs','vapid_keys','audit_pending'];
  t text; cols text; exprs text; missing text; n_exp bigint; n_got bigint; total bigint := 0;
begin
  select string_agg(c.tname, ', ') into missing from _cnt c where c.tname <> all (tbls);
  if missing is not null then
    raise exception 'SQLite-Tabellen ohne Ziel in Postgres: %', missing;
  end if;

  execute 'truncate table ' || array_to_string(tbls, ', ') || ' cascade';

  foreach t in array tbls loop
    select coalesce((select c.n from _cnt c where c.tname = t), 0) into n_exp;
    if n_exp = 0 then continue; end if;

    -- Quellspalte -> Zielspalte (Umbenennungen aus _rename, sonst gleicher Name)
    create temp table if not exists _map (src text, dst text) on commit drop;
    truncate _map;
    insert into _map
      select k, coalesce((select r.dst from _rename r where r.tname = t and r.src = k), k)
      from _imp i, jsonb_object_keys(i.data -> 0) k where i.tname = t;

    select string_agg(m.src, ', ' order by m.src) into missing
    from _map m where not exists (
      select 1 from pg_attribute a
      where a.attrelid = format('public.%I', t)::regclass and a.attname = m.dst
        and a.attnum > 0 and not a.attisdropped);
    if missing is not null then
      raise exception 'Tabelle %: SQLite-Spalten ohne Postgres-Ziel: %', t, missing;
    end if;

    select string_agg(quote_ident(a.attname), ', ' order by a.attnum),
           -- SQLite schreibt fehlende Werte oft als '' (z. B. archived_at); fuer alle
           -- Nicht-Text-Typen wird '' zu NULL. Text behaelt '' unveraendert.
           string_agg(case when tp.typcategory = 'A'
                        then format('case when nullif(r->>%L, '''') is null then null else array(select jsonb_array_elements_text((r->>%L)::jsonb))::%s end',
                                    m.src, m.src, format_type(a.atttypid, a.atttypmod))
                        when tp.typcategory = 'S'
                        then format('(r->>%L)::%s', m.src, format_type(a.atttypid, a.atttypmod))
                        else format('nullif(r->>%L, '''')::%s', m.src, format_type(a.atttypid, a.atttypmod)) end,
                      ', ' order by a.attnum)
      into cols, exprs
    from pg_attribute a
    join pg_type tp on tp.oid = a.atttypid
    join _map m on m.dst = a.attname
    where a.attrelid = format('public.%I', t)::regclass and a.attnum > 0 and not a.attisdropped;

    execute format('insert into public.%I (%s) select %s from _imp i, jsonb_array_elements(i.data) r where i.tname = %L',
                   t, cols, exprs, t);
    execute format('select count(*) from public.%I', t) into n_got;
    if n_got <> n_exp then
      raise exception 'Tabelle %: erwartet % Zeilen, importiert %', t, n_exp, n_got;
    end if;
    total := total + n_got;
    raise notice '% : % Zeilen', rpad(t, 32), n_got;
  end loop;
  raise notice 'gesamt: % Zeilen', total;
end $$;

create table public._goloom_sqlite_import (
  imported_at timestamptz not null default now(),
  source_rows bigint not null
);
insert into public._goloom_sqlite_import (source_rows) select sum(n) from _cnt;
