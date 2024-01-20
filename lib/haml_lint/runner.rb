# frozen_string_literal: true

require 'parallel'

module HamlLint
  # Responsible for running the applicable linters against the desired files.
  class Runner
    # Runs the appropriate linters against the desired files given the specified
    # options.
    #
    # @param [Hash] options
    # @option options :config_file [String] path of configuration file to load
    # @option options :config [HamlLint::Configuration] configuration to use
    # @option options :excluded_files [Array<String>]
    # @option options :included_linters [Array<String>]
    # @option options :excluded_linters [Array<String>]
    # @option options :fail_fast [true, false] flag for failing after first failure
    # @option options :fail_level
    # @option options :reporter [HamlLint::Reporter]
    # @return [HamlLint::Report] a summary of all lints found
    def run(options = {})
      @config = load_applicable_config(options)
      @files = extract_applicable_files(config, options)
      @linter_selector = HamlLint::LinterSelector.new(config, options)
      @fail_fast = options.fetch(:fail_fast, false)
      @cache = {}
      @autocorrect = options[:autocorrect]
      @autocorrect_only = options[:autocorrect_only]

      report(options)
    end

    private

    # The {HamlLint::Configuration} that should be used for this run.
    #
    # @return [HamlLint::Configuration]
    attr_reader :config

    # A flag for whether to fail after the first failure.
    #
    # @return [true, false]
    attr_reader :fail_fast

    # !@method fail_fast?
    #   Checks whether to fail after the first failure.
    #
    #   @return [true, false]
    alias fail_fast? fail_fast

    # The list of files to lint during this run.
    #
    # @return [Array<String>]
    attr_reader :files

    # The selector for which linters to run during this run.
    #
    # @return [HamlLint::LinterSelector]
    attr_reader :linter_selector

    # Returns the {HamlLint::Configuration} that should be used given the
    # specified options.
    #
    # @param options [Hash]
    # @return [HamlLint::Configuration]
    def load_applicable_config(options)
      if options[:config]
        options[:config]
      elsif options[:auto_gen_config]
        HamlLint::ConfigurationLoader.load_applicable_config(
          options[:config_file],
          exclude_files: [HamlLint::ConfigurationLoader::AUTO_GENERATED_FILE]
        )
      else
        HamlLint::ConfigurationLoader.load_applicable_config(options[:config_file])
      end
    end

    # Runs all provided linters using the specified config against the given
    # file.
    #
    # @param file [Hash]
    # @param linter_selector [HamlLint::LinterSelector]
    # @param config [HamlLint::Configuration]
    def collect_lints(file, linter_selector, config)
      begin
        document = HamlLint::Document.new(file[:io].read, file: file[:file_path], config: config)
      rescue HamlLint::Exceptions::ParseError => e
        return [HamlLint::Lint.new(HamlLint::Linter::Syntax.new(config), file,
                                   e.line, e.to_s, :error)]
      end

      linters = linter_selector.linters_for_file(file[:file_path])
      lint_arrays = []

      if @autocorrect
        lint_arrays << autocorrect_document(document, linters)
      end

      unless @autocorrect_only
        lint_arrays << linters.map do |linter|
          linter.run(document)
        end
      end
      lint_arrays.flatten
    end

    # Out of the provided linters, runs those that support autocorrect
    # against the specified document.
    # Updates the document and returns the lints that were corrected.
    #
    # @param document [HamlLint::Document]
    # @param linter_selector [HamlLint::LinterSelector]
    # @return [Array<HamlLint::Lint>]
    def autocorrect_document(document, linters)
      lint_arrays = []

      autocorrecting_linters = linters.select(&:supports_autocorrect?)
      lint_arrays << autocorrecting_linters.map do |linter|
        linter.run(document, autocorrect: @autocorrect)
      end

      document.write_to_disk!

      lint_arrays
    end

    # Returns the list of files that should be linted given the specified
    # configuration and options.
    #
    # @param config [HamlLint::Configuration]
    # @param options [Hash]
    # @return [Array<Hash>]
    def extract_applicable_files(config, options)
      if options[:stdin]
        [{ io: $stdin, file_path: options[:stdin]}]
      else
        included_patterns = options[:files]
        excluded_patterns = config['exclude']
        excluded_patterns += options.fetch(:excluded_files, [])

        HamlLint::FileFinder.new(config).find(included_patterns, excluded_patterns).map do |file_path|
          { io: File.new(file_path), file_path: file_path }
        end
      end
    end

    # Process the files and add them to the given report.
    #
    # @param report [HamlLint::Report]
    # @return [void]
    def process_files(report)
      files.each do |file|
        process_file(file, report)
        break if report.failed? && fail_fast?
      end
    end

    # Process a file and add it to the given report.
    #
    # @param file [String] the name of the file to process
    # @param report [HamlLint::Report]
    # @return [void]
    def process_file(file, report)
      lints = @cache[file[:file_path]] || collect_lints(file, linter_selector, config)
      lints.each { |lint| report.add_lint(lint) }
      report.finish_file(file, lints)
    end

    # Generates a report based on the given options.
    #
    # @param options [Hash]
    # @option options :reporter [HamlLint::Reporter] the reporter to report with
    # @return [HamlLint::Report]
    def report(options)
      report = HamlLint::Report.new(reporter: options[:reporter], fail_level: options[:fail_level])
      report.start(@files)
      warm_cache if options[:parallel]
      process_files(report)
      report
    end

    # Cache the result of processing lints in parallel.
    #
    # @return [void]
    def warm_cache
      results = Parallel.map(files) do |file|
        lints = collect_lints(file, linter_selector, config)
        [file[:file_path], lints]
      end
      @cache = results.to_h
    end
  end
end
