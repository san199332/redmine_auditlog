Redmine Auditlog
-------

Provides full auditlog for user actions in Redmine instance.

### Warning
Attention this version only works on 5.x

To work with redmine version 5.0.3 add to config/application.rb:

config.active_record.yaml_column_permitted_classes = [
      Symbol,
      ActiveSupport::HashWithIndifferentAccess,
      ActiveSupport::TimeWithZone,
      Time,
      Date,
      ActiveSupport::TimeZone,
      ActionController::Parameters
    ]

How to install
-------
```
  $ cd /var/www/redmine/plugins
  $ git clone https://github.com/RealEnder/redmine_auditlog
  $ cd /var/www/redmine
  $ bundle install
  $ cd /var/www/redmine/plugins/redmine_auditlog
  $ RAILS_ENV="production" rails generate audited:install # If using PostgreSQL, add "--audited-changes-column-type jsonb" for more efficient storage
  $ cd ../..
  $ rake db:migrate RAILS_ENV="production"
```
Then restart Redmine.

ClickHouse JSON audit storage
-------

The plugin can additionally stream every created `audited` record to ClickHouse over the native HTTP endpoint. The regular Redmine database audit table is still used by the `audited` gem; ClickHouse is an append-only JSON mirror intended for long-term storage, search, and analytics.

Set `REDMINE_AUDITLOG_CLICKHOUSE_URL` to enable the exporter:

```
REDMINE_AUDITLOG_CLICKHOUSE_URL=http://127.0.0.1:8123
REDMINE_AUDITLOG_CLICKHOUSE_DATABASE=redmine
REDMINE_AUDITLOG_CLICKHOUSE_TABLE=redmine_audits
REDMINE_AUDITLOG_CLICKHOUSE_USER=default
REDMINE_AUDITLOG_CLICKHOUSE_PASSWORD=secret
REDMINE_AUDITLOG_CLICKHOUSE_CREATE_TABLE=true
REDMINE_AUDITLOG_CLICKHOUSE_ASYNC_INSERT=true
REDMINE_AUDITLOG_CLICKHOUSE_TIMEOUT=3
REDMINE_AUDITLOG_CLICKHOUSE_PURGE_AFTER_EXPORT=false
REDMINE_AUDITLOG_CLICKHOUSE_BATCH_SIZE=1000
REDMINE_AUDITLOG_CLICKHOUSE_EXTERNAL_URL=https://external-clickhouse.example.com:8443
REDMINE_AUDITLOG_CLICKHOUSE_EXTERNAL_DATABASE=redmine
REDMINE_AUDITLOG_CLICKHOUSE_EXTERNAL_TABLE=redmine_audits
REDMINE_AUDITLOG_CLICKHOUSE_EXTERNAL_USER=default
REDMINE_AUDITLOG_CLICKHOUSE_EXTERNAL_PASSWORD=secret
```

Configuration:

* `REDMINE_AUDITLOG_CLICKHOUSE_URL` - ClickHouse HTTP endpoint. If blank or unset, ClickHouse export is disabled.
* `REDMINE_AUDITLOG_CLICKHOUSE_DATABASE` - database name, defaults to `default`.
* `REDMINE_AUDITLOG_CLICKHOUSE_TABLE` - table name, defaults to `redmine_audits`.
* `REDMINE_AUDITLOG_CLICKHOUSE_USER` and `REDMINE_AUDITLOG_CLICKHOUSE_PASSWORD` - optional HTTP basic auth credentials.
* `REDMINE_AUDITLOG_CLICKHOUSE_CREATE_TABLE` - creates a MergeTree table automatically unless set to `false`.
* `REDMINE_AUDITLOG_CLICKHOUSE_ASYNC_INSERT` - set to `true` to use ClickHouse asynchronous inserts. When a task is going to delete local rows after export, the plugin waits for the async insert result before deleting.
* `REDMINE_AUDITLOG_CLICKHOUSE_TIMEOUT` - HTTP open/read timeout in seconds, defaults to `3`.
* `REDMINE_AUDITLOG_CLICKHOUSE_PURGE_AFTER_EXPORT` - set to `true` to delete the local Redmine audit row only after a successful ClickHouse insert. Keep it `false` unless ClickHouse is your primary audit store.
* `REDMINE_AUDITLOG_CLICKHOUSE_BATCH_SIZE` - batch size for maintenance rake tasks, defaults to `1000`.
* `REDMINE_AUDITLOG_CLICKHOUSE_EXTERNAL_URL` - optional external ClickHouse HTTP endpoint used by `redmine_auditlog:clickhouse:sync_external`.
* `REDMINE_AUDITLOG_CLICKHOUSE_EXTERNAL_DATABASE` and `REDMINE_AUDITLOG_CLICKHOUSE_EXTERNAL_TABLE` - external database/table names. They default to the local ClickHouse database/table values.
* `REDMINE_AUDITLOG_CLICKHOUSE_EXTERNAL_USER` and `REDMINE_AUDITLOG_CLICKHOUSE_EXTERNAL_PASSWORD` - optional HTTP basic auth credentials for the external ClickHouse.
* `REDMINE_AUDITLOG_CLICKHOUSE_EXTERNAL_CREATE_TABLE` - creates the external table during sync unless set to `false`.
* `REDMINE_AUDITLOG_CLICKHOUSE_EXTERNAL_ASYNC_INSERT` - set to `true` to use asynchronous inserts on the external ClickHouse.

ClickHouse-primary installation
-------

The `audited` gem still needs the local Redmine `audits` table because audit rows are created inside the Redmine database transaction first. To use ClickHouse as the only long-term audit storage, install the local table as usual, enable ClickHouse export, and turn on immediate local cleanup after successful export.

Example production install:

```
cd /var/www/redmine/plugins
git clone https://github.com/RealEnder/redmine_auditlog
cd /var/www/redmine
bundle install
cd /var/www/redmine/plugins/redmine_auditlog
RAILS_ENV=production rails generate audited:install
cd ../..
rake db:migrate RAILS_ENV=production
```

Then configure Redmine, systemd, Docker, or the shell that starts Redmine with ClickHouse-primary mode:

```
REDMINE_AUDITLOG_CLICKHOUSE_URL=http://127.0.0.1:8123
REDMINE_AUDITLOG_CLICKHOUSE_DATABASE=redmine
REDMINE_AUDITLOG_CLICKHOUSE_TABLE=redmine_audits
REDMINE_AUDITLOG_CLICKHOUSE_USER=default
REDMINE_AUDITLOG_CLICKHOUSE_PASSWORD=secret
REDMINE_AUDITLOG_CLICKHOUSE_CREATE_TABLE=true
REDMINE_AUDITLOG_CLICKHOUSE_ASYNC_INSERT=true
REDMINE_AUDITLOG_CLICKHOUSE_PURGE_AFTER_EXPORT=true
```

With `REDMINE_AUDITLOG_CLICKHOUSE_PURGE_AFTER_EXPORT=true`, every new audit row is inserted into ClickHouse first and then removed from the local Redmine audit table. If ClickHouse is unavailable or rejects the insert, the local row is kept and the error is logged.

This mode matches a setup where MySQL should not retain audit history: the row is still created briefly by `audited`, but after a successful local ClickHouse insert it is removed from MySQL automatically.

For already existing local audit history, run a backfill once after enabling ClickHouse:

```
REDMINE_AUDITLOG_CLICKHOUSE_PURGE_AFTER_BACKFILL=true \
RAILS_ENV=production rake redmine_auditlog:clickhouse:backfill
```

Rows are sent with `FORMAT JSONEachRow`. The table stores both normalized fields (`event_time`, `auditable_type`, `user_id`, `action`, and so on) and JSON payload strings:

* `audited_changes_json` - the JSON representation of the `audited_changes` payload.
* `audit_json` - the full exported audit row as JSON.

If you manage the table yourself, set `REDMINE_AUDITLOG_CLICKHOUSE_CREATE_TABLE=false` and create a compatible table, for example:

```
CREATE TABLE redmine.redmine_audits (
  redmine_audit_id UInt64,
  event_time DateTime64(6, 'UTC'),
  auditable_type LowCardinality(String),
  auditable_id Nullable(UInt64),
  associated_type Nullable(String),
  associated_id Nullable(UInt64),
  user_type Nullable(String),
  user_id Nullable(UInt64),
  username Nullable(String),
  action LowCardinality(String),
  remote_address Nullable(String),
  request_uuid Nullable(String),
  version Nullable(UInt32),
  comment Nullable(String),
  audited_changes_json String,
  audit_json String
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_time, auditable_type, auditable_id, redmine_audit_id);
```



Local-to-external ClickHouse forwarding
-------

For a two-tier setup, point `REDMINE_AUDITLOG_CLICKHOUSE_URL` to the local ClickHouse and configure the `EXTERNAL_` variables for the remote ClickHouse:

```
REDMINE_AUDITLOG_CLICKHOUSE_URL=http://127.0.0.1:8123
REDMINE_AUDITLOG_CLICKHOUSE_DATABASE=redmine
REDMINE_AUDITLOG_CLICKHOUSE_TABLE=redmine_audits
REDMINE_AUDITLOG_CLICKHOUSE_PURGE_AFTER_EXPORT=true
REDMINE_AUDITLOG_CLICKHOUSE_ASYNC_INSERT=true

REDMINE_AUDITLOG_CLICKHOUSE_EXTERNAL_URL=https://external-clickhouse.example.com:8443
REDMINE_AUDITLOG_CLICKHOUSE_EXTERNAL_DATABASE=redmine
REDMINE_AUDITLOG_CLICKHOUSE_EXTERNAL_TABLE=redmine_audits
REDMINE_AUDITLOG_CLICKHOUSE_EXTERNAL_USER=default
REDMINE_AUDITLOG_CLICKHOUSE_EXTERNAL_PASSWORD=secret
REDMINE_AUDITLOG_CLICKHOUSE_EXTERNAL_CREATE_TABLE=true
REDMINE_AUDITLOG_CLICKHOUSE_EXTERNAL_ASYNC_INSERT=true
```

New Redmine events flow as follows:

1. `audited` creates a short-lived row in the local Redmine/MySQL `audits` table.
2. The plugin writes that row to the **local ClickHouse**.
3. With `REDMINE_AUDITLOG_CLICKHOUSE_PURGE_AFTER_EXPORT=true`, the plugin deletes the local MySQL audit row after the local ClickHouse insert succeeds.
4. A scheduled task copies rows from the **local ClickHouse** to the **external ClickHouse**.

Run the local-to-external copy manually or from cron:

```
RAILS_ENV=production rake redmine_auditlog:clickhouse:sync_external
```

Optional sync filters:

* `REDMINE_AUDITLOG_CLICKHOUSE_SYNC_FROM_ID` / `REDMINE_AUDITLOG_CLICKHOUSE_SYNC_TO_ID` - copy only a local ClickHouse audit id range.
* `REDMINE_AUDITLOG_CLICKHOUSE_SYNC_OLDER_THAN_DAYS` - copy only local ClickHouse rows older than this many days.

The sync task reads `JSONEachRow` batches from the local ClickHouse table and inserts the same rows into the external ClickHouse table. If you need exactly-once external replication, use ClickHouse-native replication or a table engine/deduplication strategy on the external cluster; this rake task is intentionally simple and safe to run in controlled id ranges.

Local audit cleanup and backfill
-------

Yes, the Redmine audit table can be kept small while ClickHouse stores the long-term history. There are two supported modes:

1. **Immediate cleanup after export** - set `REDMINE_AUDITLOG_CLICKHOUSE_PURGE_AFTER_EXPORT=true`. After a newly created audit row is inserted into ClickHouse successfully, the plugin deletes that same row from the local Redmine database.
2. **Scheduled cleanup** - keep local rows for a retention period and periodically run a rake task that exports old rows to ClickHouse before deleting them.

Backfill existing audit rows to ClickHouse without deleting them:

```
RAILS_ENV=production rake redmine_auditlog:clickhouse:backfill
```

Backfill and delete each row only after a successful ClickHouse export:

```
REDMINE_AUDITLOG_CLICKHOUSE_PURGE_AFTER_BACKFILL=true \
RAILS_ENV=production rake redmine_auditlog:clickhouse:backfill
```

Delete local rows older than 30 days, exporting each row to ClickHouse first by default:

```
REDMINE_AUDITLOG_CLICKHOUSE_OLDER_THAN_DAYS=30 \
RAILS_ENV=production rake redmine_auditlog:clickhouse:purge
```

Useful task filters:

* `REDMINE_AUDITLOG_CLICKHOUSE_OLDER_THAN_DAYS` - only process rows older than this many days.
* `REDMINE_AUDITLOG_CLICKHOUSE_FROM_ID` / `REDMINE_AUDITLOG_CLICKHOUSE_TO_ID` - limit backfill by local audit id range.
* `REDMINE_AUDITLOG_CLICKHOUSE_PURGE_AFTER_BACKFILL=true` - delete rows during backfill only after successful ClickHouse export.
* `REDMINE_AUDITLOG_CLICKHOUSE_EXPORT_BEFORE_PURGE=false` - delete old local rows without exporting first. Use only if you already know those rows exist in ClickHouse.

For production, the safer pattern is to keep `REDMINE_AUDITLOG_CLICKHOUSE_PURGE_AFTER_EXPORT=false`, run `redmine_auditlog:clickhouse:purge` from cron, and retain at least several days of local audit rows as a buffer.

How to upgrade
-------
```
  $ cd /var/www/redmine
  $ bundle install
  $ cd /var/www/redmine/plugins/redmine_auditlog
  $ RAILS_ENV="production" rails generate audited:upgrade # If using PostgreSQL, add "--audited-changes-column-type jsonb" for more efficient storage
  $ cd ../..
  $ rake db:migrate RAILS_ENV="production"
```
Then restart Redmine.

How to remove
-------
```
  $ cd /var/www/redmine
  $ rake redmine:plugins:migrate NAME=redmine_auditlog VERSION=0 RAILS_ENV=production
  $ rm -rf plugins/redmine_auditlog
```
Then restart Redmine. This will not remove audit table.


Compatible with:	Redmine 5.x  
Tested with Redmine 5.0.3

License
-------
Copyright 2022 Alexandr Antonov
This plugin is released under the GPL v3 license. See  
LICENSE for more information.
