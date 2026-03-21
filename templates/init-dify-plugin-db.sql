-- AGMind: Create dify_plugin database for plugin-daemon
-- Mounted into /docker-entrypoint-initdb.d/ — runs on first DB init only
-- For existing volumes, the enhanced healthcheck + create_plugin_db() fallback handles it

SELECT 'CREATE DATABASE dify_plugin'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'dify_plugin')\gexec
