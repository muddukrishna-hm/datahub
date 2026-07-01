#!/bin/bash
# Creates the 'ranger' database used by Apache Ranger within this shared Postgres instance.
# The primary 'logistics' database is created automatically via POSTGRES_DB in docker-compose.
set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres <<-EOSQL
    SELECT 'CREATE USER rangeradmin WITH ENCRYPTED PASSWORD ''${RANGER_DB_PASSWORD}'''
    WHERE NOT EXISTS (SELECT FROM pg_user WHERE usename = 'rangeradmin')\gexec

    SELECT 'CREATE DATABASE ranger OWNER rangeradmin'
    WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'ranger')\gexec

    GRANT ALL PRIVILEGES ON DATABASE ranger TO rangeradmin;
EOSQL
