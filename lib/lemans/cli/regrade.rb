# frozen_string_literal: true

require "json"

module Lemans
  class CLI < Thor
    # Re-grades stored results from the checks.json each trial left behind,
    # against a mapping: every check of the task as `fail` (required) or
    # `fail (allowed)` (extra), plus the grading section. Nothing runs.
    class Regrade
      ALLOWED = "fail (allowed)"
      CHECKS = "checks.json"

      # A checks.json-shaped file: `checks`, `grading`, and the features as
      # `features: { name => [checks] }`.
      Mapping = Struct.new(:checks, :base_credit, :points, :features, :stray_features, keyword_init: true) do
        def self.from_json(data)
          checks = data["checks"] or raise ConfigError, "a mapping needs a `checks` section"
          grading = data["grading"] || {}
          declared = grading["points"] || {}
          allowed = checks.select { |_, status| status == ALLOWED }.keys
          features = data["features"] || {}
          unknown = features.values.flatten - checks.keys
          raise ConfigError, "the mapping's features name unknown checks: #{unknown.inspect}" if unknown.any?

          new(checks:, base_credit: grading["base_credit"], points: allowed.to_h { [ it, declared.fetch(it, 1) ] }, features:)
        end

        def names = checks.keys.sort

        def allowed?(check) = points.key?(check)

        def grading = { base_credit:, points: }.compact
      end

      Change = Struct.new(:result, :reward, :credit, :features, keyword_init: true)

      class << self
        def mapping_from_file(path) = Mapping.from_json(JSON.parse(File.read(path)))

        def mapping_for(task)
          scanner = Trial::Verifier::TestScanner.for(task)
          raise ConfigError, "#{task.name} has no verification_test.rb to read the grading from" unless scanner

          checks = scanner.tests.to_h { [ it, scanner.points.key?(it) ? ALLOWED : "fail" ] }
          Mapping.new(checks:, base_credit: scanner.base_credit, points: scanner.points,
                      features: scanner.features, stray_features: scanner.stray_features)
        end
      end

      attr_reader :store, :task, :mapping

      def initialize(store, task, mapping:)
        @store = store
        @task = task
        @mapping = mapping
      end

      def results = runs.select(&:scored?)

      # Older multistep results lack the task's step count; returns the runs that gained it.
      def record_total_steps!(total)
        runs.select { it.steps && it.total_steps != total }.each do |result|
          result.total_steps = total
          store.save(result)
        end
      end

      # A statically read mapping is only trusted once a stored checks.json
      # names exactly its checks.
      def verify_mapping!
        stored = results.lazy.filter_map { checks_of(it) }.first
        return unless stored

        names = stored.fetch("checks", {}).keys.sort
        return if names == mapping.names

        raise ConfigError, "the checks read from verification_test.rb do not match the stored #{CHECKS} " \
                           "(missing: #{(names - mapping.names).inspect}, unexpected: #{(mapping.names - names).inspect}); " \
                           "pass --mapping with a #{CHECKS}-shaped file"
      end

      def execute!
        changes = []
        skipped = []
        results.each do |result|
          checks = checks_of(result)
          next skipped << [ result, "no #{CHECKS}" ] unless checks
          next skipped << [ result, "#{CHECKS} names other checks than the mapping" ] unless checks.fetch("checks", {}).keys.sort == mapping.names

          change = regrade!(result, checks)
          change ? changes << change : skipped << [ result, "unchanged" ]
        end
        [ changes, skipped ]
      end

      private

      def runs = @runs ||= store.query(task:).sort_by { it.id.to_s }

      def checks_of(result)
        raw = store.read_artifact(result, CHECKS)
        raw && JSON.parse(raw)
      rescue JSON::ParserError
        nil
      end

      def regrade!(result, checks)
        statuses = checks["checks"].to_h { |check, status| [ check, status_of(check, status) ] }
        failures = statuses.reject { |_, status| status == "pass" || status == ALLOWED }.keys
        allowed = checks.fetch("allowed_failures", {}).slice(*statuses.select { |_, status| status == ALLOWED }.keys)
        updated = { checks: statuses, failures:, allowed_failures: allowed }
        updated[:grading] = mapping.grading unless mapping.grading.empty?
        reward = failures.empty? ? 1.0 : 0.0
        credit = credit_of(statuses, reward)
        features = Trial::Verifier.features_from(statuses, mapping.features)
        return if reward == result.reward && credit == result.credit && features == result.features &&
                  JSON.parse(JSON.generate(updated)) == checks

        store.save_artifact(result, "#{JSON.pretty_generate(updated)}\n", path: CHECKS, force: true)
        change = Change.new(result:, reward: [ result.reward, reward ], credit: [ result.credit, credit ],
                            features: [ result.features, features ])
        store.save(result.graded!(reward, credit:, features:))
        change
      end

      def status_of(check, status)
        return status unless status == "fail" || status == ALLOWED

        mapping.allowed?(check) ? ALLOWED : "fail"
      end

      def credit_of(statuses, reward)
        return reward if mapping.base_credit.nil?
        return 0.0 if reward.zero?

        total = mapping.points.values.sum
        return reward if total.zero?

        passed = mapping.points.sum { |check, value| statuses[check] == "pass" ? value : 0 }
        (mapping.base_credit + (1 - mapping.base_credit) * (passed.to_f / total)).round(2)
      end
    end
  end
end
