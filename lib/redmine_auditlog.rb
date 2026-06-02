require 'date'
require 'json'
require 'net/http'
require 'time'
require 'uri'

module RedmineAuditlog

  module AuditlogPatch
    def self.included(base)
      base.class_eval do
        #unloadable # Send unloadable so it will not be unloaded in development
        audited
      end
    end
  end

  module AuditlogPatchUser
    def self.included(base)
      base.class_eval do
        #unloadable # Send unloadable so it will not be unloaded in development
        audited except: [:salt, :hashed_password]
      end
    end
  end

  module AuditlogPatchToken
    def self.included(base)
      base.class_eval do
        #unloadable # Send unloadable so it will not be unloaded in development
        audited except: :value
      end
    end
  end

  module AuditlogPatchAuthSource
    def self.included(base)
      base.class_eval do
        #unloadable # Send unloadable so it will not be unloaded in development
        audited except: :account_password
      end
    end
  end

  module AuditlogPatchRepository
    def self.included(base)
      base.class_eval do
        #unloadable # Send unloadable so it will not be unloaded in development
        audited except: :password
      end
    end
  end

  module Clickhouse
    ENV_PREFIX = 'REDMINE_AUDITLOG_CLICKHOUSE_'.freeze
    DEFAULT_DATABASE = 'default'.freeze
    DEFAULT_TABLE = 'redmine_audits'.freeze
    DEFAULT_TIMEOUT = 3
    DEFAULT_BATCH_SIZE = 1_000
    VALID_IDENTIFIER = /\A[A-Za-z_][A-Za-z0-9_]*\z/

    class << self
      def install!
        return unless enabled?
        return unless defined?(Audited::Audit)
        return if Audited::Audit.instance_variable_get(:@redmine_auditlog_clickhouse_installed)

        create_table! if create_table?
        Audited::Audit.after_commit(on: :create) do
          RedmineAuditlog::Clickhouse.export_after_commit(self)
        end
        Audited::Audit.instance_variable_set(:@redmine_auditlog_clickhouse_installed, true)
      end

      def enabled?
        env('URL').to_s.strip != ''
      end

      def export_after_commit(audit)
        return unless export(audit, wait_for_insert: purge_after_export?)

        purge_local_audit(audit) if purge_after_export?
      end

      def export(audit, wait_for_insert: false)
        post_query(insert_query(wait_for_insert: wait_for_insert), JSON.generate(row_for(audit)) + "\n")
      rescue StandardError => e
        log_error("ClickHouse audit export failed: #{e.class}: #{e.message}")
        nil
      end

      def purge_local_audit(audit)
        audit.class.where(id: audit.id).delete_all
      rescue StandardError => e
        log_error("Local audit purge failed: #{e.class}: #{e.message}")
        nil
      end

      def purge_after_export?
        env('PURGE_AFTER_EXPORT').to_s == 'true'
      end

      def purge_after_backfill?
        env('PURGE_AFTER_BACKFILL').to_s == 'true'
      end

      def batch_size
        env('BATCH_SIZE').to_i.positive? ? env('BATCH_SIZE').to_i : DEFAULT_BATCH_SIZE
      end

      def create_table!
        post_query(create_table_query, '')
      rescue StandardError => e
        log_error("ClickHouse audit table creation failed: #{e.class}: #{e.message}")
        nil
      end

      def database
        identifier(env('DATABASE'), DEFAULT_DATABASE)
      end

      def table
        identifier(env('TABLE'), DEFAULT_TABLE)
      end

      private

      def row_for(audit)
        changes = json_value(audit_value(audit, :audited_changes))
        row = {
          redmine_audit_id: integer_value(audit_value(audit, :id)) || 0,
          event_time: time_value(audit_value(audit, :created_at)),
          auditable_type: string_value(audit_value(audit, :auditable_type)) || '',
          auditable_id: integer_value(audit_value(audit, :auditable_id)),
          associated_type: string_value(audit_value(audit, :associated_type)),
          associated_id: integer_value(audit_value(audit, :associated_id)),
          user_type: string_value(audit_value(audit, :user_type)),
          user_id: integer_value(audit_value(audit, :user_id)),
          username: string_value(audit_value(audit, :username)),
          action: string_value(audit_value(audit, :action)) || '',
          remote_address: string_value(audit_value(audit, :remote_address)),
          request_uuid: string_value(audit_value(audit, :request_uuid)),
          version: integer_value(audit_value(audit, :version)),
          comment: string_value(audit_value(audit, :comment)),
          audited_changes_json: JSON.generate(changes)
        }
        row[:audit_json] = JSON.generate(row.dup)
        row
      end

      def audit_value(audit, field)
        audit.public_send(field) if audit.respond_to?(field)
      end

      def json_value(value)
        case value
        when Hash
          value.transform_keys(&:to_s).transform_values { |entry| json_value(entry) }
        when Array
          value.map { |entry| json_value(entry) }
        when Time, Date, DateTime
          value.iso8601
        else
          value
        end
      end

      def string_value(value)
        return nil if value.nil?

        value.to_s
      end

      def integer_value(value)
        return nil if value.nil?
        return nil if value.to_s == ''

        value.to_i
      end

      def time_value(value)
        time = value.respond_to?(:utc) ? value.utc : Time.now.utc
        time.iso8601(6)
      end

      def insert_query(wait_for_insert: false)
        settings = async_insert? ? " SETTINGS async_insert=1, wait_for_async_insert=#{wait_for_insert ? 1 : 0}" : ''
        "INSERT INTO #{qualified_table}#{settings} FORMAT JSONEachRow"
      end

      def create_table_query
        <<~SQL
          CREATE TABLE IF NOT EXISTS #{qualified_table} (
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
          ORDER BY (event_time, auditable_type, auditable_id, redmine_audit_id)
        SQL
      end

      def qualified_table
        "#{database}.#{table}"
      end

      def post_query(query, body)
        endpoint = uri
        endpoint.query = [endpoint.query, "query=#{URI.encode_www_form_component(query)}"].compact.join('&')

        request = Net::HTTP::Post.new(endpoint)
        request.basic_auth(env('USER'), env('PASSWORD')) if env('USER').to_s != ''
        request['Content-Type'] = 'application/x-ndjson'
        request.body = body

        Net::HTTP.start(endpoint.hostname, endpoint.port, use_ssl: endpoint.scheme == 'https', read_timeout: timeout, open_timeout: timeout) do |http|
          response = http.request(request)
          return response if response.is_a?(Net::HTTPSuccess)

          raise "#{response.code} #{response.message}: #{response.body}"
        end
      end

      def uri
        URI.parse(env('URL'))
      end

      def timeout
        env('TIMEOUT').to_i.positive? ? env('TIMEOUT').to_i : DEFAULT_TIMEOUT
      end

      public

      def create_table?
        env('CREATE_TABLE').to_s != 'false'
      end

      private

      def async_insert?
        env('ASYNC_INSERT').to_s == 'true'
      end

      def identifier(value, default)
        candidate = value.to_s.strip == '' ? default : value.to_s.strip
        return candidate if candidate.match?(VALID_IDENTIFIER)

        raise ArgumentError, "Invalid ClickHouse identifier: #{candidate.inspect}"
      end

      def env(name)
        ENV["#{ENV_PREFIX}#{name}"]
      end

      def log_error(message)
        if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
          Rails.logger.error(message)
        else
          warn(message)
        end
      end
    end
  end
end
