\set ON_ERROR_STOP on

BEGIN;

DO $$
DECLARE
  matching_columns integer;
BEGIN
  SELECT count(*) INTO matching_columns
  FROM information_schema.columns AS actual
  JOIN (VALUES
    ('address', 'verified_on'),
    ('address', 'registered_on'),
    ('bounceevent', 'timestamp'),
    ('file_cache', 'created_on'),
    ('file_cache', 'expires_on'),
    ('mailinglist', 'created_at'),
    ('mailinglist', 'digest_last_sent_at'),
    ('mailinglist', 'last_post_at'),
    ('member', 'last_bounce_received'),
    ('member', 'last_warning_sent'),
    ('pended', 'expiration_date'),
    ('user', '_created_on')
  ) AS expected(table_name, column_name)
    USING (table_name, column_name)
  WHERE actual.table_schema = 'public'
    AND actual.data_type = 'timestamp with time zone';

  IF matching_columns <> 12 THEN
    RAISE EXCEPTION
      'Expected 12 timestamp-with-time-zone columns before repair, found %',
      matching_columns;
  END IF;
END $$;

ALTER TABLE address
  ALTER COLUMN verified_on TYPE timestamp without time zone
    USING verified_on AT TIME ZONE 'UTC',
  ALTER COLUMN registered_on TYPE timestamp without time zone
    USING registered_on AT TIME ZONE 'UTC';
ALTER TABLE bounceevent
  ALTER COLUMN "timestamp" TYPE timestamp without time zone
    USING "timestamp" AT TIME ZONE 'UTC';
ALTER TABLE file_cache
  ALTER COLUMN created_on TYPE timestamp without time zone
    USING created_on AT TIME ZONE 'UTC',
  ALTER COLUMN expires_on TYPE timestamp without time zone
    USING expires_on AT TIME ZONE 'UTC';
ALTER TABLE mailinglist
  ALTER COLUMN created_at TYPE timestamp without time zone
    USING created_at AT TIME ZONE 'UTC',
  ALTER COLUMN digest_last_sent_at TYPE timestamp without time zone
    USING digest_last_sent_at AT TIME ZONE 'UTC',
  ALTER COLUMN last_post_at TYPE timestamp without time zone
    USING last_post_at AT TIME ZONE 'UTC';
ALTER TABLE member
  ALTER COLUMN last_bounce_received TYPE timestamp without time zone
    USING last_bounce_received AT TIME ZONE 'UTC',
  ALTER COLUMN last_warning_sent TYPE timestamp without time zone
    USING last_warning_sent AT TIME ZONE 'UTC';
ALTER TABLE pended
  ALTER COLUMN expiration_date TYPE timestamp without time zone
    USING expiration_date AT TIME ZONE 'UTC';
ALTER TABLE "user"
  ALTER COLUMN _created_on TYPE timestamp without time zone
    USING _created_on AT TIME ZONE 'UTC';

DO $$
DECLARE
  matching_columns integer;
BEGIN
  SELECT count(*) INTO matching_columns
  FROM information_schema.columns AS actual
  JOIN (VALUES
    ('address', 'verified_on'),
    ('address', 'registered_on'),
    ('bounceevent', 'timestamp'),
    ('file_cache', 'created_on'),
    ('file_cache', 'expires_on'),
    ('mailinglist', 'created_at'),
    ('mailinglist', 'digest_last_sent_at'),
    ('mailinglist', 'last_post_at'),
    ('member', 'last_bounce_received'),
    ('member', 'last_warning_sent'),
    ('pended', 'expiration_date'),
    ('user', '_created_on')
  ) AS expected(table_name, column_name)
    USING (table_name, column_name)
  WHERE actual.table_schema = 'public'
    AND actual.data_type = 'timestamp without time zone';

  IF matching_columns <> 12 THEN
    RAISE EXCEPTION
      'Expected 12 timestamp-without-time-zone columns after repair, found %',
      matching_columns;
  END IF;
END $$;

COMMIT;
