\set ON_ERROR_STOP on

BEGIN;

SET LOCAL lock_timeout = '10s';

-- pgloader mapped MySQL tinyint(1) to boolean, but Roundcube's native
-- PostgreSQL schema and queries use smallint for these core flags.
ALTER TABLE roundcube.cache_index
  ALTER COLUMN valid DROP DEFAULT,
  ALTER COLUMN valid TYPE smallint USING CASE WHEN valid THEN 1 ELSE 0 END,
  ALTER COLUMN valid SET DEFAULT 0;

ALTER TABLE roundcube.contactgroups
  ALTER COLUMN del DROP DEFAULT,
  ALTER COLUMN del TYPE smallint USING CASE WHEN del THEN 1 ELSE 0 END,
  ALTER COLUMN del SET DEFAULT 0;

ALTER TABLE roundcube.contacts
  ALTER COLUMN del DROP DEFAULT,
  ALTER COLUMN del TYPE smallint USING CASE WHEN del THEN 1 ELSE 0 END,
  ALTER COLUMN del SET DEFAULT 0;

ALTER TABLE roundcube.identities
  ALTER COLUMN del DROP DEFAULT,
  ALTER COLUMN del TYPE smallint USING CASE WHEN del THEN 1 ELSE 0 END,
  ALTER COLUMN del SET DEFAULT 0,
  ALTER COLUMN standard DROP DEFAULT,
  ALTER COLUMN standard TYPE smallint USING CASE WHEN standard THEN 1 ELSE 0 END,
  ALTER COLUMN standard SET DEFAULT 0;

-- These tables were added by later Roundcube schema updates run as postgres.
-- Their owner and owned sequences must match the application role.
ALTER TABLE roundcube.collected_addresses OWNER TO roundcube;
ALTER TABLE roundcube.filestore OWNER TO roundcube;
ALTER TABLE roundcube.responses OWNER TO roundcube;
ALTER SEQUENCE roundcube.collected_addresses_seq OWNER TO roundcube;
ALTER SEQUENCE roundcube.filestore_seq OWNER TO roundcube;
ALTER SEQUENCE roundcube.responses_seq OWNER TO roundcube;

COMMIT;
