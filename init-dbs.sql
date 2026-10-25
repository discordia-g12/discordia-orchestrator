SELECT 'CREATE DATABASE auth_db' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'auth_db')\gexec
SELECT 'CREATE DATABASE server_roles_db' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'server_roles_db')\gexec
SELECT 'CREATE DATABASE payments_db' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'payments_db')\gexec
SELECT 'CREATE DATABASE notification_db' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'notification_db')\gexec

