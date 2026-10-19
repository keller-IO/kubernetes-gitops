-- Einmal-Migration SQLite -> Postgres (Kite v0.16.0): Daten aus _imp in die
-- Kite-Tabellen. Spalten werden ueber den Namen zugeordnet und explizit auf
-- den Postgres-Typ gecastet (SQLite liefert Text/Integer: 0/1 -> boolean,
-- '2006-01-02 15:04:05.999+00:00' -> timestamptz/timestamp). Secret-Spalten
-- sind AES-GCM/base64-Text mit KITE_ENCRYPT_KEY und werden unveraendert
-- uebernommen. Reihenfolge = Fremdschluessel (role_assignments -> roles,
-- resource_histories -> users). Jede Abweichung bricht ab.
-- Das Schema-Dump setzt search_path = '', daher alles schema-qualifiziert.
do $$
declare
  tbls text[] := array[
    'users','roles','role_assignments','resource_histories','passkey_credentials',
    'clusters','general_settings','ldap_settings','o_auth_providers','resource_templates',
    'pending_sessions','helm_repositories','scheduled_tasks','plugins','plugin_settings'];
  t text; cols text; exprs text; missing text; n_exp bigint; n_got bigint; total bigint := 0;
  seq text;
begin
  select string_agg(c.tname, ', ') into missing from pg_temp._cnt c where c.tname <> all (tbls);
  if missing is not null then
    raise exception 'SQLite-Tabellen ohne Ziel in Postgres: %', missing;
  end if;

  foreach t in array tbls loop
    select coalesce((select c.n from pg_temp._cnt c where c.tname = t), 0) into n_exp;
    if n_exp = 0 then continue; end if;

    select string_agg(k, ', ' order by k) into missing
    from pg_temp._imp i, pg_catalog.jsonb_object_keys(i.data -> 0) k
    where i.tname = t and not exists (
      select 1 from pg_catalog.pg_attribute a
      where a.attrelid = pg_catalog.format('public.%I', t)::pg_catalog.regclass and a.attname = k
        and a.attnum > 0 and not a.attisdropped);
    if missing is not null then
      raise exception 'Tabelle %: SQLite-Spalten ohne Postgres-Ziel: %', t, missing;
    end if;

    -- '' wird bei Nicht-Text-Typen zu NULL; Text behaelt '' unveraendert.
    select string_agg(pg_catalog.quote_ident(a.attname), ', ' order by a.attnum),
           string_agg(case when tp.typcategory = 'S'
                        then pg_catalog.format('(r->>%L)::%s', a.attname, pg_catalog.format_type(a.atttypid, a.atttypmod))
                        else pg_catalog.format('nullif(r->>%L, '''')::%s', a.attname, pg_catalog.format_type(a.atttypid, a.atttypmod)) end,
                      ', ' order by a.attnum)
      into cols, exprs
    from pg_catalog.pg_attribute a
    join pg_catalog.pg_type tp on tp.oid = a.atttypid
    where a.attrelid = pg_catalog.format('public.%I', t)::pg_catalog.regclass and a.attnum > 0 and not a.attisdropped
      and exists (select 1 from pg_temp._imp i, pg_catalog.jsonb_object_keys(i.data -> 0) k
                  where i.tname = t and k = a.attname);

    execute pg_catalog.format('insert into public.%I (%s) select %s from pg_temp._imp i, pg_catalog.jsonb_array_elements(i.data) r where i.tname = %L',
                   t, cols, exprs, t);
    execute pg_catalog.format('select count(*) from public.%I', t) into n_got;
    if n_got <> n_exp then
      raise exception 'Tabelle %: erwartet % Zeilen, importiert %', t, n_exp, n_got;
    end if;

    -- Explizite IDs uebernommen: Sequenz hinter das Maximum setzen.
    seq := pg_catalog.pg_get_serial_sequence(pg_catalog.format('public.%I', t), 'id');
    if seq is not null then
      execute pg_catalog.format('select pg_catalog.setval(%L, (select max(id) from public.%I))', seq, t);
    end if;

    total := total + n_got;
    raise notice '% : % Zeilen', pg_catalog.rpad(t, 24), n_got;
  end loop;
  raise notice 'gesamt: % Zeilen', total;
end $$;

create table public._kite_sqlite_import (
  imported_at timestamptz not null default pg_catalog.now(),
  source_rows bigint not null
);
insert into public._kite_sqlite_import (source_rows) select sum(n) from pg_temp._cnt;
