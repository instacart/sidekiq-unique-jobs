require 'spec_helper'
require 'celluloid'
require 'sidekiq/worker'
require 'sidekiq-unique-jobs'
require 'sidekiq/scheduled'
require 'sidekiq_unique_jobs/middleware/server/unique_jobs'

describe 'Client' do
  describe 'with real redis' do
    before do
      Sidekiq.redis = REDIS
      Sidekiq.redis(&:flushdb)
      QueueWorker.sidekiq_options unique: nil, unique_job_expiration: nil
    end

    class QueueWorker
      include Sidekiq::Worker
      sidekiq_options queue: 'customqueue'
      def perform(_x)
      end
    end

    class PlainClass
      def run(_x)
      end
    end

    it 'does not push duplicate messages when configured for unique only' do
      QueueWorker.sidekiq_options unique: true
      10.times { Sidekiq::Client.push('class' => QueueWorker, 'queue' => 'customqueue',  'args' => [1, 2]) }
      result = Sidekiq.redis { |c| c.llen('queue:customqueue') }
      expect(result).to eq 1
    end

    it 'does push duplicate messages to different queues' do
      QueueWorker.sidekiq_options unique: true
      Sidekiq::Client.push('class' => QueueWorker, 'queue' => 'customqueue',  'args' => [1, 2])
      Sidekiq::Client.push('class' => QueueWorker, 'queue' => 'customqueue2',  'args' => [1, 2])
      q1_length = Sidekiq.redis { |c| c.llen('queue:customqueue') }
      q2_length = Sidekiq.redis { |c| c.llen('queue:customqueue2') }
      expect(q1_length).to eq 1
      expect(q2_length).to eq 1
    end

    it 'does not queue duplicates when when calling delay' do
      10.times { PlainClass.delay(unique: true, queue: 'customqueue').run(1) }
      result = Sidekiq.redis { |c| c.llen('queue:customqueue') }
      expect(result).to eq 1
    end

    it 'does not schedule duplicates when calling perform_in' do
      QueueWorker.sidekiq_options unique: true
      10.times { QueueWorker.perform_in(60, [1, 2]) }
      result = Sidekiq.redis { |c| c.zcount('schedule', -1, Time.now.to_f + 2 * 60) }
      expect(result).to eq 1
    end

    it 'enqueues previously scheduled job' do
      QueueWorker.sidekiq_options unique: true
      QueueWorker.perform_in(60 * 60, 1, 2)

      # time passes and the job is pulled off the schedule:
      Sidekiq::Client.push('class' => QueueWorker, 'queue' => 'customqueue', 'args' => [1, 2])

      result = Sidekiq.redis { |c| c.llen('queue:customqueue') }
      expect(result).to eq 1
    end

    it 'sets an expiration when provided by sidekiq options' do
      one_hour_expiration = 60 * 60
      QueueWorker.sidekiq_options unique: true, unique_job_expiration: one_hour_expiration
      Sidekiq::Client.push('class' => QueueWorker, 'queue' => 'customqueue',  'args' => [1, 2])

      payload_hash = SidekiqUniqueJobs::PayloadHelper.get_payload('QueueWorker', 'customqueue', [1, 2])
      actual_expires_at = Sidekiq.redis { |c| c.ttl(payload_hash) }

      Sidekiq.redis { |c| c.llen('queue:customqueue') }
      expect(actual_expires_at).to be_within(2).of(one_hour_expiration)
    end

    it 'does push duplicate messages when not configured for unique only' do
      QueueWorker.sidekiq_options unique: false
      10.times { Sidekiq::Client.push('class' => QueueWorker, 'queue' => 'customqueue',  'args' => [1, 2]) }
      expect(Sidekiq.redis { |c| c.llen('queue:customqueue') }).to eq 10

      result = Sidekiq.redis { |c| c.llen('queue:customqueue') }
      expect(result).to eq 10
    end

    describe 'when unique_args is defined' do
      before { SidekiqUniqueJobs.config.unique_args_enabled = true }
      after  { SidekiqUniqueJobs.config.unique_args_enabled = false }

      class QueueWorkerWithFilterMethod < QueueWorker
        sidekiq_options unique: true, unique_args: :args_filter

        def self.args_filter(*args)
          args.first
        end
      end

      class QueueWorkerWithFilterProc < QueueWorker
        # slightly contrived example of munging args to the
        # worker and removing a random bit.
        sidekiq_options unique: true, unique_args: (lambda do |args|
          a = args.last.dup
          a.delete(:random)
          [args.first, a]
        end)
      end

      it 'does not push duplicate messages based on args filter method' do
        expect(QueueWorkerWithFilterMethod).to respond_to(:args_filter)
        expect(QueueWorkerWithFilterMethod.get_sidekiq_options['unique_args']).to eq :args_filter

        (0..10).each do |i|
          Sidekiq::Client.push(
            'class' => QueueWorkerWithFilterMethod,
            'queue' => 'customqueue',
            'args' => [1, i]
          )
        end
        result = Sidekiq.redis { |c| c.llen('queue:customqueue') }
        expect(result).to eq 1
      end

      it 'does not push duplicate messages based on args filter proc' do
        expect(QueueWorkerWithFilterProc.get_sidekiq_options['unique_args']).to be_a(Proc)

        10.times do
          Sidekiq::Client.push(
            'class' => QueueWorkerWithFilterProc,
            'queue' => 'customqueue',
            'args' => [1, { random: rand, name: 'foobar' }]
          )
        end
        result = Sidekiq.redis { |c| c.llen('queue:customqueue') }
        expect(result).to eq 1
      end

      describe 'when unique_on_all_queues is set' do
        before { QueueWorker.sidekiq_options unique: true, unique_on_all_queues: true }
        before { QueueWorker.sidekiq_options unique: true }
        it 'does not push duplicate messages on different queues' do
          Sidekiq::Client.push('class' => QueueWorker, 'queue' => 'customqueue',  'args' => [1, 2])
          Sidekiq::Client.push('class' => QueueWorker, 'queue' => 'customqueue2',  'args' => [1, 2])
          q1_length = Sidekiq.redis { |c| c.llen('queue:customqueue') }
          q2_length = Sidekiq.redis { |c| c.llen('queue:customqueue2') }
          expect(q1_length).to eq 1
          expect(q2_length).to eq 0
        end
      end
    end

    # TODO: If anyone know of a better way to check that the expiration for scheduled
    # jobs are set around the same time as the scheduled job itself feel free to improve.
    it 'expires the payload_hash when a scheduled job is scheduled at' do
      require 'active_support/all'
      QueueWorker.sidekiq_options unique: true

      at = 15.minutes.from_now
      expected_expires_at = (Time.at(at) - Time.now.utc) + SidekiqUniqueJobs.config.default_expiration

      QueueWorker.perform_in(at, 'mike')
      payload_hash = SidekiqUniqueJobs::PayloadHelper.get_payload('QueueWorker', 'customqueue', ['mike'])

      # deconstruct this into a time format we can use to get a decent delta for
      actual_expires_at = Sidekiq.redis { |c| c.ttl(payload_hash) }

      expect(actual_expires_at).to be_within(2).of(expected_expires_at)
    end

    describe "BaseJobWrapper" do
      context "running a BaseJobWrapper job" do
        before do
          @args = [ {'job_id' => 123, 'job_class' => 'RegularJob'}, 1, [], nil]
          class BaseJobWrapper; include Sidekiq::Worker; end
        end

        it "removes job_id from any hash in args" do
          unique_args = SidekiqUniqueJobs::PayloadHelper.yield_unique_args(BaseJobWrapper, @args)
          expect(unique_args).to eq( [{'job_class' => 'RegularJob'}, 1, [], nil] )
        end

        it "leaves job_id in original args array" do
          SidekiqUniqueJobs::PayloadHelper.yield_unique_args(BaseJobWrapper, @args)
          expect(@args).to eq( [ {'job_id' => 123, 'job_class' => 'RegularJob'}, 1, [], nil] )
        end

        it "leaves other types of values in args alone" do
          unique_args = SidekiqUniqueJobs::PayloadHelper.yield_unique_args(BaseJobWrapper, @args)
          expect(unique_args).to eq( [{'job_class' => 'RegularJob'}, 1, [], nil] )
        end

        it "is a noop if not working on a BaseJobWrapper call" do
          unique_args = SidekiqUniqueJobs::PayloadHelper.yield_unique_args(QueueWorker, @args)
          expect(unique_args).to eq @args
        end
      end

      context "not running a BaseJobWrapper" do
        it "doesn't blow up if BaseJobWrapper does not exist" do
          args = [ {'job_id' => 123, 'job_class' => 'RegularJob'}, 1, [], nil]
          unique_args = SidekiqUniqueJobs::PayloadHelper.yield_unique_args(QueueWorker, args)
          expect(unique_args).to eq args
        end
      end

    end
  end
end
