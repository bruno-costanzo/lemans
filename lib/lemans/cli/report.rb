# frozen_string_literal: true

require "csv"

module Lemans
  class CLI < Thor
    # Renders stored results as a table or CSV. The store is the source of
    # truth; rows are plain hashes derived from Result records.
    class Report
      COLUMNS = %i[task agent model reward credit completed_steps total_steps outcome scored cost_usd steps tokens
                   duration started_at trial tags detail].freeze
      TABLE_COLUMNS = %i[task agent model reward credit progress outcome cost_usd steps tokens duration trial].freeze
      NUMERIC_COLUMNS = %i[reward credit progress cost_usd steps tokens duration].freeze

      attr_reader :rows, :unreadable

      class << self
        def load(store, tags: nil, names: nil, metadata: nil)
          rows = store.query(task: names, tags:, metadata:).map { row_from(it) }
          new(rows.sort_by { [ it[:task].to_s, it[:started_at].to_s, it[:trial].to_s ] },
              unreadable: store.unreadable.size)
        end

        def row_from(result)
          usage = result.usage
          {
            task: result.task,
            agent: result.agent,
            model: result.model,
            reward: result.reward,
            credit: result.credit,
            features: result.features,
            completed_steps: result.steps&.size,
            total_steps: result.total_steps,
            outcome: result.status,
            scored: result.scored?,
            detail: result.detail,
            cost_usd: usage&.cost_usd,
            steps: usage&.steps,
            # Tokens the model actually consumed and produced; cache reads stay
            # out, matching how providers meter a run.
            tokens: usage && (usage.input_tokens.to_i + usage.output_tokens.to_i),
            duration: result.duration,
            started_at: result.started_at&.iso8601,
            trial: result.id,
            tags: result.tags.map(&:to_s)
          }
        end

        # Steps completed out of the task's steps; unknown for older runs halted midway
        def progress_ratio(row) = row[:total_steps] && Rational(row[:completed_steps], row[:total_steps])

        # Feature columns carry a prefix no regular column has
        def feature_column(name) = :"feat:#{name}"

        def feature_of(row, column) = row[:features]&.[](column.to_s.delete_prefix("feat:"))

        # A bench may name no model at all (nop, oracle); the summary needs a
        # label, not a nil for ljust to crash on.
        def short_model(model) = model.to_s.split("/").last || "(default)"

        # One definition of the numbers everyone quotes — total, scored,
        # invalid, solved — so the views can never drift apart.
        def tally(rows)
          scored = rows.count { it[:scored] }
          {
            total: rows.size,
            scored:,
            invalid: rows.size - scored,
            solved: rows.count { it[:reward].to_f >= 1.0 }
          }
        end

        # `--metadata category:full-features`, repeated, means every pair must match.
        def metadata_filter(specs)
          return if specs.nil? || specs.empty?

          specs.to_h do |spec|
            key, value = spec.split(":", 2)
            raise ConfigError, "--metadata: expected key:value (got #{spec.inspect})" if value.nil? || key.empty?

            [ key, value ]
          end
        end

        # One sorting rule for every view. `score-credit` sorts by score, then
        # credit; `^` reverses a column's natural order. Column names may hold
        # dashes (features), so the longest known name wins.
        def sort_columns(spec, allowed:)
          names = allowed.map(&:to_s).sort_by { -it.length }
          rest = spec.to_s
          columns = []
          loop do
            reversed = rest.start_with?("^")
            rest = rest.delete_prefix("^")
            name = names.find { rest == it || rest.start_with?("#{it}-") }
            raise ConfigError, "--sort: unknown column in #{spec.inspect} (try #{allowed.join(", ")})" unless name

            columns << [ name.to_sym, reversed ]
            rest = rest.delete_prefix(name).delete_prefix("-")
            return columns if rest.empty?
          end
        end

        # Keys are [value, descending] pairs, tried in order; rows that never
        # measured a value sink below the rest, and ties keep their order.
        def sort_rows(rows, keys)
          keyed = rows.each_with_index.map { |row, index| [ keys.map { |value, _| value.call(row) }, index, row ] }
          keyed.sort { |(a, i, _), (b, j, _)| compare(a, b, keys.map(&:last)).nonzero? || i <=> j }.map(&:last)
        end

        private def compare(values, others, descending)
          values.zip(others, descending).each do |value, other, desc|
            next if value == other
            return 1 if value.nil?
            return -1 if other.nil?

            order = value <=> other
            return desc ? -order : order unless order.zero?
          end
          0
        end
      end

      def initialize(rows, unreadable: 0)
        @rows = with_total_steps(rows)
        @unreadable = unreadable
      end

      # A store holding only unreadable results is not empty: the report's
      # job is to say so.
      def empty? = rows.empty? && unreadable.zero?

      # Numbers rank best-first the way a leaderboard reads; names sort A-Z.
      # Trials that never measured the column sink to the bottom either way.
      def order_by!(spec)
        keys = self.class.sort_columns(spec, allowed: TABLE_COLUMNS + feature_columns).map do |column, reversed|
          numeric = NUMERIC_COLUMNS.include?(column) || feature_columns.include?(column)
          [ ->(row) { sort_value(row, column) }, numeric != reversed ]
        end
        @rows = self.class.sort_rows(rows, keys)
        self
      end

      def summary
        self.class.tally(rows).merge(cost_usd: rows.sum { it[:cost_usd].to_f })
      end

      def fractional? = rows.any? { it[:credit] && it[:credit] != it[:reward] }

      def multistep? = rows.any? { it[:completed_steps] }

      # The features every task in view tracks; tasks with no graded run yet have no say.
      def feature_columns
        @feature_columns ||= rows.select { it[:features] }
                                 .group_by { it[:task] }
                                 .map { |_, group| group.flat_map { it[:features].keys }.uniq }
                                 .reduce(:&).to_a.sort.map { self.class.feature_column(it) }
      end

      def table_columns
        columns = TABLE_COLUMNS - [ (:credit unless fractional?), (:progress unless multistep?) ].compact
        columns.insert(columns.index(:trial), *feature_columns)
      end

      def to_rows
        [ table_columns.map(&:to_s) ] +
          rows.map do |row|
            table_columns.map do |column|
              case column
              when :model then display(short_model(row[:model]))
              when :progress then progress(row)
              when *feature_columns then { true => "✓", false => "✗" }.fetch(self.class.feature_of(row, column), "-")
              else display(row[column])
              end
            end
          end
      end

      def summary_lines
        per_model = rows.group_by { short_model(it[:model]) }
        lines =
          if per_model.size > 1
            width = per_model.keys.map(&:length).max
            per_model.map { |model, group| "#{model.ljust(width)}  #{stats(group)}" } +
              [ "#{"total".ljust(width)}  #{stats(rows)}" ]
          else
            [ stats(rows) ]
          end
        lines[-1] = "#{lines[-1]} · #{unreadable} unreadable result(s) skipped" if unreadable.positive?
        lines
      end

      def to_csv
        CSV.generate do |csv|
          csv << COLUMNS + feature_columns
          rows.each do |row|
            csv << COLUMNS.map { |column| column == :tags ? Array(row[:tags]).join(" ") : row[column] } +
                   feature_columns.map { self.class.feature_of(row, it) }
          end
        end
      end

      private

      def sort_value(row, column)
        if column == :model then short_model(row[:model])
        elsif column == :progress then self.class.progress_ratio(row)
        elsif feature_columns.include?(column) then { true => 1, false => 0 }[self.class.feature_of(row, column)]
        else row[column]
        end
      end

      # Older multistep results lack the task's step count: a run of the same
      # task that solved it went through every step.
      def with_total_steps(rows)
        known = rows.filter_map do |row|
          total = row[:total_steps] || (row[:completed_steps] if row[:reward].to_f >= 1.0)
          [ row[:task], total ] if total
        end.to_h
        rows.map do |row|
          next row if row[:total_steps] || !row[:completed_steps] || !known[row[:task]]

          row.merge(total_steps: known[row[:task]])
        end
      end

      # The rank divides solved by scored, not total: invalid trials measured nothing.
      def stats(group)
        totals = self.class.tally(group).merge(cost_usd: group.sum { it[:cost_usd].to_f })
        rank = totals[:scored].positive? ? " (#{(100.0 * totals[:solved] / totals[:scored]).round}%)" : ""
        "#{totals[:total]} trials: #{totals[:scored]} scored, #{totals[:invalid]} invalid, " \
          "#{totals[:solved]} solved#{rank} · $#{format("%.4f", totals[:cost_usd])}#{pass_at_k(group)}"
      end

      def pass_at_k(group)
        cells = group.select { it[:scored] }.group_by { [ it[:model], it[:task] ] }.values
        sizes = cells.map(&:size).uniq
        return "" unless sizes.any? { it > 1 }

        solved = cells.count { |trials| trials.any? { it[:reward].to_f >= 1.0 } }
        label = sizes.size == 1 ? "pass@#{sizes.first}" : "pass@k"
        " · #{label} #{solved}/#{cells.size} tasks (#{(100.0 * solved / cells.size).round}%)"
      end

      def short_model(model) = self.class.short_model(model)

      def progress(row) = row[:completed_steps] ? "#{row[:completed_steps]}/#{row[:total_steps] || "?"}" : "-"

      def display(value)
        case value
        when nil then "-"
        when Float then format("%g", value.round(4))
        else value.to_s
        end
      end
    end
  end
end
