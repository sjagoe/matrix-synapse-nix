# Configuring postgres for the first time

- On the primary:

  1. Execute ./init/initdb.sql on the primary.

  2. Set passwords for repmgr and matrix_synapse users with `\password [user]` in `psql`

  3. Execute `sudo -u postgres repmgr -f /etc/repmgr.conf primary register` on the primary.

  4. `sudo -u postgres repmgr cluster show` should show primary node running

- On the replica:

  1. Check that we can connect to the primary (connection string from primary repmgr.conf):
```
sudo -u postgres psql 'host=10.37.0.4 user=repmgr dbname=repmgr connect_timeout=2 passfile=/data/postgresql/repmgr-passwd'
```

  2. `sudo systemctl stop postgresql.service`
  3. `sudo rm -rf /data/postgresql/12`
  4. `sudo -u postgres PGPASSFILE=/data/postgresql/repmgr-passwd repmgr -h "<primary-IP>" -U repmgr -d repmgr standby clone --dry-run`
  5. `sudo -u postgres PGPASSFILE=/data/postgresql/repmgr-passwd repmgr -h "<primary-IP>" -U repmgr -d repmgr standby clone`
  6. `sudo systemctl start postgresql.service`
  7. `sudo -u postgres repmgr standby register`
  8. `repmgr cluster show` should show both nodes running
  9. Connect to the primary and `SELECT * FROM pg_stat_replication;` and `SELECT * FROM pg_stat_wal_receiver;`
