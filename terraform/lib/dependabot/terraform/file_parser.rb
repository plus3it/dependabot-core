# frozen_string_literal: true

require "cgi"
require "excon"
require "nokogiri"
require "open3"
require "dependabot/dependency"
require "dependabot/file_parsers"
require "dependabot/file_parsers/base"
require "dependabot/git_commit_checker"
require "dependabot/shared_helpers"
require "dependabot/errors"

module Dependabot
  module Terraform
    class FileParser < Dependabot::FileParsers::Base
      require "dependabot/file_parsers/base/dependency_set"

      ARCHIVE_EXTENSIONS = %w(.zip .tbz2 .tgz .txz).freeze

      def parse
        @dependency_set = DependencySet.new

        terraform_files.each do |file|
          parse_terraform_file(file)
        end

        terragrunt_files.each do |file|
          parse_terragrunt_file(file)
        end

        terragrunt_legacy_files.each do |file|
          parse_terragrunt_legacy_file(file)
        end

        @dependency_set.dependencies
      end

      private

      def parse_terraform_file(file)
        parsed_file = parsed_file(file)
        modules = parsed_file.fetch("module", []).map(&:first)
        modules = parsed_file.fetch("module_calls", []) if modules.empty?
        modules.each do |name, details|
          @dependency_set << build_terraform_dependency(file, name, details)
        end
      end

      def parse_terragrunt_file(file)
        modules = parsed_file(file).fetch("terraform", []).
                  map { |k, v| [k, v] }.to_h

        modules.each do |name, details|
          next unless name == "source"

          @dependency_set << build_terraform_dependency(
            file, "", [Hash[name, details]]
          )
        end
      end

      def parse_terragrunt_legacy_file(file)
        content = parsed_file(file).fetch("terragrunt", [])
        return if content.empty?

        modules = content[0].map { |k, v| [k, v] }.to_h
        return unless modules.key?("terraform")

        modules["terraform"].each do |terraform_module|
          terraform_module.each do |name, details|
            next unless name == "source"

            @dependency_set << build_terraform_dependency(
              file, "", [Hash[name, details]]
            )
          end
        end
      end

      def dependency_name(source, name)
        if name != ""
          source[:type] == "registry" ? source[:module_identifier] : name
        elsif Source.from_url(source[:url])
          Source.from_url(source[:url]).repo
        else
          source[:url]
        end
      end

      def build_terraform_dependency(file, name, details)
        details = details.first if details.is_a?(Array)
        source = source_from(details)
        dep_name = dependency_name(source, name)
        version_req = details["version"]&.strip
        version =
          if source[:type] == "git" then version_from_ref(source[:ref])
          elsif version_req&.match?(/^\d/) then version_req
          end
        Dependency.new(
          name: dep_name,
          version: version,
          package_manager: "terraform",
          requirements: [
            requirement: version_req,
            groups: [],
            file: file.name,
            source: source
          ]
        )
      end

      # Full docs at https://www.terraform.io/docs/modules/sources.html
      def source_from(details_hash)
        raw_source = details_hash.fetch("source")
        bare_source = get_proxied_source(raw_source)

        source_details =
          case source_type(bare_source)
          when :http_archive, :path, :mercurial, :s3
            { type: source_type(bare_source).to_s, url: bare_source }
          when :github, :bitbucket, :git
            git_source_details_from(bare_source)
          when :registry
            registry_source_details_from(bare_source)
          end

        source_details[:proxy_url] = raw_source if raw_source != bare_source
        source_details
      end

      def registry_source_details_from(source_string)
        parts = source_string.split("//").first.split("/")

        if parts.count == 3
          {
            type: "registry",
            registry_hostname: "registry.terraform.io",
            module_identifier: source_string.split("//").first
          }
        elsif parts.count == 4
          {
            type: "registry",
            registry_hostname: parts.first,
            module_identifier: parts[1..3].join("/")
          }
        else
          msg = "Invalid registry source specified: '#{source_string}'"
          raise DependencyFileNotEvaluatable, msg
        end
      end

      def git_source_details_from(source_string)
        git_url = source_string.strip.gsub(/^git::/, "")
        git_url = "https://" + git_url unless git_url.start_with?("git@") || git_url.include?("://")

        bare_uri =
          if git_url.include?("git@")
            git_url.split("git@").last.sub(":", "/")
          else
            git_url.sub(%r{.*?://}, "")
          end

        querystr = URI.parse("https://" + bare_uri).query
        git_url = git_url.gsub("?#{querystr}", "").split(%r{(?<!:)//}).first

        {
          type: "git",
          url: git_url,
          branch: nil,
          ref: CGI.parse(querystr.to_s)["ref"].first&.split(%r{(?<!:)//})&.first
        }
      end

      def version_from_ref(ref)
        version_regex = GitCommitChecker::VERSION_REGEX
        return unless ref&.match?(version_regex)

        ref.match(version_regex).named_captures.fetch("version")
      end

      # rubocop:disable Metrics/PerceivedComplexity
      # See https://www.terraform.io/docs/modules/sources.html#http-urls for
      # details of how Terraform handle HTTP(S) sources for modules
      def get_proxied_source(raw_source)
        return raw_source unless raw_source.start_with?("http")

        uri = URI.parse(raw_source.split(%r{(?<!:)//}).first)
        return raw_source if uri.path.end_with?(*ARCHIVE_EXTENSIONS)
        return raw_source if URI.parse(raw_source).query.include?("archive=")

        url = raw_source.split(%r{(?<!:)//}).first + "?terraform-get=1"

        response = Excon.get(
          url,
          idempotent: true,
          **SharedHelpers.excon_defaults
        )

        return response.headers["X-Terraform-Get"] if response.headers["X-Terraform-Get"]

        doc = Nokogiri::XML(response.body)
        doc.css("meta").find do |tag|
          tag.attributes&.fetch("name", nil)&.value == "terraform-get"
        end&.attributes&.fetch("content", nil)&.value
      end
      # rubocop:enable Metrics/PerceivedComplexity

      # rubocop:disable Metrics/PerceivedComplexity
      def source_type(source_string)
        return :path if source_string.start_with?(".")
        return :github if source_string.include?("github.com")
        return :bitbucket if source_string.start_with?("bitbucket.org/")
        return :git if source_string.start_with?("git::")
        return :mercurial if source_string.start_with?("hg::")
        return :s3 if source_string.start_with?("s3::")

        raise "Unknown src: #{source_string}" if source_string.split("/").first.include?("::")

        return :registry unless source_string.start_with?("http")

        path_uri = URI.parse(source_string.split(%r{(?<!:)//}).first)
        query_uri = URI.parse(source_string)
        return :http_archive if path_uri.path.end_with?(*ARCHIVE_EXTENSIONS)
        return :http_archive if query_uri.query.include?("archive=")

        raise "HTTP source, but not an archive!"
      end
      # rubocop:enable Metrics/PerceivedComplexity

      def parsed_file(file)
        @parsed_buildfile ||= {}
        # handle terragrunt's new format
        if file.name.include? ".hcl"
          parsed_file_helper(
            file,
            "#{terraform_parser_path('hcl2json')} tmp.tf"
          )
        end
        # handle terraform 0.11 and 0.12
        begin
          parsed_file_helper(
            file,
            "#{terraform_parser_path('json2hcl')} -reverse < tmp.tf"
          )
        rescue SharedHelpers::HelperSubprocessFailed => e
          @msg = "hcl2json: " + e.message.strip + "\n"
          begin
            parsed_file_helper(
              file,
              # terraform-config-inspect only works when provided a directory
              "terraform-config-inspect --json .",
              # specifying $GOPATH/bin:$PATH here doesn't seem to work..
              "PATH" => "/opt/go/gopath/bin:$PATH"
            )
          rescue SharedHelpers::HelperSubprocessFailed => e
            @msg << "terraform-config-inspect: " + e.message.strip
            raise Dependabot::DependencyFileNotParseable.new(file.path, @msg)
          end
        end
      end

      def parsed_file_helper(file, command, env = { "PATH" => "$PATH" })
        @parsed_buildfile[file.name] ||=
          SharedHelpers.in_a_temporary_directory do
            File.write("tmp.tf", file.content)

            start = Time.now
            stdout, stderr, process = Open3.capture3(env, command)
            time_taken = Time.now - start

            unless process.success?
              raise SharedHelpers::HelperSubprocessFailed.new(
                message: stderr,
                error_context: {
                  command: command,
                  time_taken: time_taken,
                  process_exit_value: process.to_s
                }
              )
            end
            JSON.parse(stdout)
          end
      end

      def terraform_parser_path(binary)
        helper_bin_dir = File.join(native_helpers_root, "terraform/bin")
        Pathname.new(File.join(helper_bin_dir, binary)).cleanpath.to_path
      end

      def native_helpers_root
        default_path = File.join(__dir__, "../../../helpers/install-dir")
        ENV.fetch("DEPENDABOT_NATIVE_HELPERS_PATH", default_path)
      end

      def terraform_files
        dependency_files.select { |f| f.name.end_with?(".tf") }
      end

      def terragrunt_files
        dependency_files.select { |f| f.name.end_with?(".hcl") }
      end

      def terragrunt_legacy_files
        dependency_files.select { |f| f.name.end_with?(".tfvars") }
      end

      def check_required_files
        return if [
          *terraform_files,
          *terragrunt_files,
          *terragrunt_legacy_files
        ].any?

        raise "No Terraform configuration file!"
      end
    end
  end
end

Dependabot::FileParsers.
  register("terraform", Dependabot::Terraform::FileParser)
