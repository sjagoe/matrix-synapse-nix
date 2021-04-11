CREATE USER repmgr WITH SUPERUSER;
CREATE DATABASE repmgr OWNER repmgr
    ENCODING 'UTF-8'
    LC_COLLATE 'en_US.UTF-8'
    LC_CTYPE 'en_US.UTF-8';

CREATE USER matrix_synapse;
CREATE DATABASE matrix_synapse
    ENCODING 'UTF-8'
    LC_COLLATE='C'
    LC_CTYPE='C'
    template=template0;
GRANT ALL PRIVILEGES
    ON DATABASE matrix_synapse
    TO matrix_synapse;

CREATE USER telegraf;
