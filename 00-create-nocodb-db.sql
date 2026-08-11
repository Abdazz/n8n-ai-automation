-- Exécuté automatiquement au premier démarrage du volume Postgres
-- (avant schema.sql, par ordre alphabétique : 00- avant 01-)
-- Crée la base dédiée aux métadonnées NocoDB, séparée des données applicatives.

SELECT 'CREATE DATABASE nocodb_meta OWNER ' || current_user
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'nocodb_meta')
\gexec
