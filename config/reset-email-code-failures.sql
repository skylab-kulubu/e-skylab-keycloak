-- Run with psql -X --set=ON_ERROR_STOP=1 against the intended Keycloak database/schema.
-- Prompts stay in memory; never put real realm/user values or credentials in this file.
\set ON_ERROR_STOP on
\prompt 'Realm id: ' counter_realm_id
\prompt 'User id: ' counter_user_id
BEGIN;
SET LOCAL lock_timeout = '5s';
WITH locked_user AS MATERIALIZED (
    SELECT id FROM user_entity
    WHERE realm_id = :'counter_realm_id' AND id = :'counter_user_id'
    FOR UPDATE
)
SELECT count(*) = 1 AS counter_user_found FROM locked_user \gset
\if :counter_user_found
    DELETE FROM user_attribute
    WHERE user_id = :'counter_user_id' AND name = 'skyEmailCodeConsecutiveFailures';
    COMMIT;
    \echo 'Consecutive e-mail code counter reset; daily and sending budgets are unchanged.'
\else
    ROLLBACK;
    DO $$ BEGIN RAISE EXCEPTION 'No local user matched that realm and user id; nothing changed.'; END $$;
\endif
\unset counter_realm_id
\unset counter_user_id
\unset counter_user_found
