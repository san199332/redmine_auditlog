namespace :redmine_auditlog do
  namespace :clickhouse do
    desc 'Export existing local audits to ClickHouse. Set REDMINE_AUDITLOG_CLICKHOUSE_PURGE_AFTER_BACKFILL=true to delete each row after a successful export.'
    task backfill: :environment do
      abort 'ClickHouse export is disabled. Set REDMINE_AUDITLOG_CLICKHOUSE_URL.' unless RedmineAuditlog::Clickhouse.enabled?

      RedmineAuditlog::Clickhouse.create_table! if RedmineAuditlog::Clickhouse.create_table?

      exported = 0
      deleted = 0
      scope = Audited::Audit.all
      scope = scope.where('id >= ?', ENV['REDMINE_AUDITLOG_CLICKHOUSE_FROM_ID'].to_i) if ENV['REDMINE_AUDITLOG_CLICKHOUSE_FROM_ID'].to_i.positive?
      scope = scope.where('id <= ?', ENV['REDMINE_AUDITLOG_CLICKHOUSE_TO_ID'].to_i) if ENV['REDMINE_AUDITLOG_CLICKHOUSE_TO_ID'].to_i.positive?
      scope = scope.where('created_at < ?', Time.now.utc - ENV['REDMINE_AUDITLOG_CLICKHOUSE_OLDER_THAN_DAYS'].to_i.days) if ENV['REDMINE_AUDITLOG_CLICKHOUSE_OLDER_THAN_DAYS'].to_i.positive?

      scope.find_each(batch_size: RedmineAuditlog::Clickhouse.batch_size) do |audit|
        next unless RedmineAuditlog::Clickhouse.export(audit, wait_for_insert: RedmineAuditlog::Clickhouse.purge_after_backfill?)

        exported += 1
        if RedmineAuditlog::Clickhouse.purge_after_backfill?
          RedmineAuditlog::Clickhouse.purge_local_audit(audit)
          deleted += 1
        end
      end

      puts "Exported #{exported} audit row(s) to ClickHouse."
      puts "Deleted #{deleted} local audit row(s)." if RedmineAuditlog::Clickhouse.purge_after_backfill?
    end

    desc 'Delete local Redmine audit rows older than REDMINE_AUDITLOG_CLICKHOUSE_OLDER_THAN_DAYS. Export first by default, or set REDMINE_AUDITLOG_CLICKHOUSE_EXPORT_BEFORE_PURGE=false.'
    task purge: :environment do
      days = ENV['REDMINE_AUDITLOG_CLICKHOUSE_OLDER_THAN_DAYS'].to_i
      abort 'Set REDMINE_AUDITLOG_CLICKHOUSE_OLDER_THAN_DAYS to a positive number.' unless days.positive?

      cutoff = Time.now.utc - days.days
      scope = Audited::Audit.where('created_at < ?', cutoff)
      export_before_purge = ENV['REDMINE_AUDITLOG_CLICKHOUSE_EXPORT_BEFORE_PURGE'].to_s != 'false'
      abort 'ClickHouse export is disabled. Set REDMINE_AUDITLOG_CLICKHOUSE_URL or REDMINE_AUDITLOG_CLICKHOUSE_EXPORT_BEFORE_PURGE=false.' if export_before_purge && !RedmineAuditlog::Clickhouse.enabled?

      exported = 0
      deleted = 0
      failed = 0

      scope.find_each(batch_size: RedmineAuditlog::Clickhouse.batch_size) do |audit|
        if export_before_purge
          if RedmineAuditlog::Clickhouse.export(audit, wait_for_insert: true)
            exported += 1
          else
            failed += 1
            next
          end
        end

        RedmineAuditlog::Clickhouse.purge_local_audit(audit)
        deleted += 1
      end

      puts "Exported #{exported} audit row(s) to ClickHouse before purge." if export_before_purge
      puts "Skipped #{failed} row(s) because ClickHouse export failed." if failed.positive?
      puts "Deleted #{deleted} local audit row(s) older than #{days} day(s)."
    end

    desc 'Copy rows from the local ClickHouse audit table to an external ClickHouse table.'
    task sync_external: :environment do
      from_id = ENV['REDMINE_AUDITLOG_CLICKHOUSE_SYNC_FROM_ID']
      to_id = ENV['REDMINE_AUDITLOG_CLICKHOUSE_SYNC_TO_ID']
      older_than_days = ENV['REDMINE_AUDITLOG_CLICKHOUSE_SYNC_OLDER_THAN_DAYS']
      synced = RedmineAuditlog::Clickhouse.sync_external!(from_id: from_id, to_id: to_id, older_than_days: older_than_days)

      abort 'External ClickHouse sync failed. Check Redmine logs.' if synced.nil?

      puts "Copied #{synced} local ClickHouse audit row(s) to external ClickHouse."
    end

  end
end
