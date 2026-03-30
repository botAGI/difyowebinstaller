-- AGMind: Create litellm database for LiteLLM AI Gateway
-- Mounted into /docker-entrypoint-initdb.d/ -- runs on first DB init only
-- For existing volumes, LiteLLM creates tables automatically on first connect

SELECT 'CREATE DATABASE litellm'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'litellm')\gexec
