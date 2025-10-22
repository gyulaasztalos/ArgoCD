### Data Migration after the initial deployment
1. **Export DB:**
    `adocker exec -t paperless-db-1 pg_dump -U paperless -d paperless > /mnt/UNVR-Pro/private/paperless/paperless_db_backup.sql`
2. **Copy data and media directories:**
    * `rsync -av data /mnt/UNVR-Pro/private/paperless/`
    * `rsync -av media /mnt/UNVR-Pro/private/paperless`
3. **On one of the k3s nodes, copy the DB dump into the primary Postgres POD:**
    * `kubectl -n databases cp /mnt/UNVR-Pro/private/paperless/paperless_db_backup.sql postgres-8:/var/lib/postgresql/data/`
    * `kubectl exec postgres-8 -n databases -it -- bash`
    * `psql --username paperless -W -h 127.0.0.1 -f paperless_db_backup.sql`
4. **Copy the data and media directories into the Paperless-NGX POD:**
    * `kubectl -n paperless-ngx cp /mnt/UNVR-Pro/private/paperless/media paperless-ngx-b6d6476dd-xfs5d:/usr/src/paperless/`
    * `kubectl -n paperless-ngx cp /mnt/UNVR-Pro/private/paperless/data paperless-ngx-b6d6476dd-xfs5d:/usr/src/paperless/`
5. **Restart Paperless-NGX:**
    * `kubectl delete pod -n paperless-ngx paperless-ngx-b6d6476dd-xfs5d`
6. **Login with password and re-enable the Authentik SSO on your profile**

### Grant permissions to paperless user in order to be able to migrate the DB during version upgrades
1. **Connect with postgres user to the UNIX socket in the postgres-rw pod**
   * `psql -U postgres -d paperless`
2. **Run SQLs**
    * `GRANT USAGE, CREATE ON SCHEMA public TO paperless;`
    * `ALTER DEFAULT PRIVILEGES IN SCHEMA  public GRANT ALL ON TABLES TO paperless;`
    * `GRANT ALL PRIVILEGES ON ALL TABLES IN   SCHEMA public TO paperless;`
    * `GRANT ALL PRIVILEGES ON ALL SEQUENCES   IN SCHEMA public TO paperless;`
