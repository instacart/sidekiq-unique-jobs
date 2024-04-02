require 'digest'
require 'sidekiq_unique_jobs/connectors'

module SidekiqUniqueJobs
  module Middleware
    module Client
      module Strategies
        class Unique
          def self.elegible?
            true
          end

          def self.review(worker_class, item, queue, redis_pool = nil)
            new(worker_class, item, queue, redis_pool).review { yield }
          end

          def initialize(worker_class, item, queue, redis_pool = nil)
            @worker_class = SidekiqUniqueJobs.worker_class_constantize(worker_class)
            @item = item
            @queue = queue
            @redis_pool = redis_pool
          end

          def review
            item['unique_hash'] = payload_hash
            return unless unique_for_connection?
            yield
          end

          private

          attr_reader :item, :worker_class, :redis_pool, :queue

          # rubocop:disable MethodLength
          def unique_for_connection?
            unique = false
            connection do |conn|
              conn.watch(payload_hash)

              if conn.get(payload_hash).to_i == 1 ||
                 (conn.get(payload_hash).to_i == 2 && item['at'])
                # if the job is already queued, or is already scheduled and
                # we're trying to schedule again, abort
                conn.unwatch
              else
                # if the job was previously scheduled and is now being queued,
                # or we've never seen it before
                expires_at = unique_job_expiration || SidekiqUniqueJobs.config.default_expiration
                expires_at = ((Time.at(item['at']) - Time.now.utc) + expires_at).to_i if item['at']

                unique = conn.multi do |pipeline|
                  # set value of 2 for scheduled jobs, 1 for queued jobs.
                  pipeline.setex(payload_hash, expires_at, item['at'] ? 2 : 1)
                end
              end
            end
            unique
          end
          # rubocop:enable MethodLength

          def connection(&block)
            SidekiqUniqueJobs::Connectors.connection(redis_pool, &block)
          end

          def payload_hash
            SidekiqUniqueJobs::PayloadHelper.get_payload(item['class'], item['queue'], item['args'])
          end

          def unique_job_expiration
            item['unique_job_expiration'] || worker_class.get_sidekiq_options['unique_job_expiration']
          end
        end
      end
    end
  end
end
