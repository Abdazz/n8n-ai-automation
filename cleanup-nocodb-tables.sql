-- À exécuter sur golden_market APRÈS avoir basculé NC_DB_JSON vers nocodb_meta
-- et confirmé que NocoDB redémarre correctement avec la nouvelle base.
-- Supprime les tables de métadonnées NocoDB qui avaient été créées par erreur
-- dans golden_market (avant la séparation des bases).

DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN
        SELECT tablename FROM pg_tables
        WHERE schemaname = 'public' AND tablename LIKE 'nc\_%'
    LOOP
        EXECUTE 'DROP TABLE IF EXISTS public.' || quote_ident(r.tablename) || ' CASCADE';
    END LOOP;
END $$;
