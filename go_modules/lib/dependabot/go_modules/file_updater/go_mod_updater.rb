# frozen_string_literal: true

require "dependabot/shared_helpers"
require "dependabot/errors"
require "dependabot/go_modules/file_updater"
require "dependabot/go_modules/native_helpers"
require "dependabot/go_modules/resolvability_errors"

module Dependabot
  module GoModules
    class FileUpdater
      class GoModUpdater
        # Turn off the module proxy for now, as it's causing issues with
        # private git dependencies
        ENVIRONMENT = { "GOPRIVATE" => "*" }.freeze

        RESOLVABILITY_ERROR_REGEXES = [
          # The checksum in go.sum does not match the downloaded content
          /verifying .*: checksum mismatch/.freeze,
          /go: .*: go.mod has post-v\d+ module path/
        ].freeze

        REPO_RESOLVABILITY_ERROR_REGEXES = [
          /fatal: The remote end hung up unexpectedly/,
          /repository '.+' not found/,
          # (Private) module could not be fetched
          /go: .*: git fetch .*: exit status 128/.freeze,
          # (Private) module could not be found
          /cannot find module providing package/.freeze,
          # Package in module was likely renamed or removed
          /module .* found \(.*\), but does not contain package/m.freeze,
          # Package pseudo-version does not match the version-control metadata
          # https://golang.google.cn/doc/go1.13#version-validation
          /go: .*: invalid pseudo-version/m.freeze,
          # Package does not exist, has been pulled or cannot be reached due to
          # auth problems with either git or the go proxy
          /go: .*: unknown revision/m.freeze
        ].freeze

        MODULE_PATH_MISMATCH_REGEXES = [
          /go get: \S+ updating to\n\s+\S+\sparsing\sgo.mod:\n\s+module declares its path as: \S+\n\s+but was required as: \S+/,
          /go: ([^@\s]+)(?:@[^\s]+)?: .* has non-.* module path "(.*)" at/,
          /go: ([^@\s]+)(?:@[^\s]+)?: .* unexpected module path "(.*)"/,
          /go: ([^@\s]+)(?:@[^\s]+)?: .* declares its path as: ([\S]*)/m
        ].freeze

        OUT_OF_DISK_REGEXES = [
          %r{input/output error}.freeze,
          /no space left on device/.freeze
        ].freeze

        GO_MOD_VERSION = /^go 1\.[\d]+$/.freeze

        def initialize(dependencies:, credentials:, repo_contents_path:,
                       directory:, options:)
          @dependencies = dependencies
          @credentials = credentials
          @repo_contents_path = repo_contents_path
          @directory = directory
          @tidy = options.fetch(:tidy, false)
          @vendor = options.fetch(:vendor, false)
        end

        def updated_go_mod_content
          updated_files[:go_mod]
        end

        def updated_go_sum_content
          updated_files[:go_sum]
        end

        private

        attr_reader :dependencies, :credentials, :repo_contents_path,
                    :directory

        def updated_files
          @updated_files ||= update_files
        end

        def update_files # rubocop:disable Metrics/AbcSize, Metrics/PerceivedComplexity
          in_repo_path do
            # Map paths in local replace directives to path hashes
            original_go_mod = File.read("go.mod")
            original_manifest = parse_manifest
            original_go_sum = File.read("go.sum") if File.exist?("go.sum")

            substitutions = replace_directive_substitutions(original_manifest)
            build_module_stubs(substitutions.values)

            # Replace full paths with path hashes in the go.mod
            substitute_all(substitutions)

            # Set the stubbed replace directives
            update_go_mod(dependencies)

            # Then run `go get` to pick up other changes to the file caused by
            # the upgrade
            run_go_get

            # If we stubbed modules, don't run `go mod {tidy,vendor}` as
            # dependencies are incomplete
            if substitutions.empty?
              run_go_mod_tidy
              run_go_vendor
            else
              substitute_all(substitutions.invert)
            end

            updated_go_sum = original_go_sum ? File.read("go.sum") : nil
            updated_go_mod = File.read("go.mod")

            # running "go get" may inject the current go version, remove it
            original_go_version = original_go_mod.match(GO_MOD_VERSION)&.to_a&.first
            updated_go_version = updated_go_mod.match(GO_MOD_VERSION)&.to_a&.first
            if original_go_version != updated_go_version
              go_mod_lines = updated_go_mod.lines
              go_mod_lines.each_with_index do |line, i|
                next unless line&.match?(GO_MOD_VERSION)

                # replace with the original version
                go_mod_lines[i] = original_go_version
                # avoid a stranded newline if there was no version originally
                go_mod_lines[i + 1] = nil if original_go_version.nil?
              end

              updated_go_mod = go_mod_lines.compact.join
            end

            { go_mod: updated_go_mod, go_sum: updated_go_sum }
          end
        end

        def run_go_mod_tidy
          return unless tidy?

          command = "go mod tidy -e"

          # we explicitly don't raise an error for 'go mod tidy' and silently
          # continue here. `go mod tidy` shouldn't block updating versions
          # because there are some edge cases where it's OK to fail (such as
          # generated files not available yet to us).
          Open3.capture3(ENVIRONMENT, command)
        end

        def run_go_vendor
          return unless vendor?

          command = "go mod vendor"
          _, stderr, status = Open3.capture3(ENVIRONMENT, command)
          handle_subprocess_error(stderr) unless status.success?
        end

        def update_go_mod(dependencies)
          deps = dependencies.map do |dep|
            {
              name: dep.name,
              version: "v" + dep.version.sub(/^v/i, ""),
              indirect: dep.requirements.empty?
            }
          end

          body = SharedHelpers.run_helper_subprocess(
            command: NativeHelpers.helper_path,
            env: ENVIRONMENT,
            function: "updateDependencyFile",
            args: { dependencies: deps }
          )

          write_go_mod(body)
        end

        def run_go_get
          tmp_go_file = "#{SecureRandom.hex}.go"

          package = Dir.glob("[^\._]*.go").any? do |path|
            !File.read(path).include?("// +build")
          end

          File.write(tmp_go_file, "package dummypkg\n") unless package

          _, stderr, status = Open3.capture3(ENVIRONMENT, "go get -d")
          handle_subprocess_error(stderr) unless status.success?
        ensure
          File.delete(tmp_go_file) if File.exist?(tmp_go_file)
        end

        def parse_manifest
          command = "go mod edit -json"
          stdout, stderr, status = Open3.capture3(ENVIRONMENT, command)
          handle_subprocess_error(stderr) unless status.success?

          JSON.parse(stdout) || {}
        end

        def in_repo_path(&block)
          SharedHelpers.in_a_temporary_repo_directory(directory, repo_contents_path) do
            SharedHelpers.with_git_configured(credentials: credentials) do
              block.call
            end
          end
        end

        def build_module_stubs(stub_paths)
          # Create a fake empty module for each local module so that
          # `go get -d` works, even if some modules have been `replace`d
          # with a local module that we don't have access to.
          stub_paths.each do |stub_path|
            Dir.mkdir(stub_path) unless Dir.exist?(stub_path)
            FileUtils.touch(File.join(stub_path, "go.mod"))
            FileUtils.touch(File.join(stub_path, "main.go"))
          end
        end

        # Given a go.mod file, find all `replace` directives pointing to a path
        # on the local filesystem, and return an array of pairs mapping the
        # original path to a hash of the path.
        #
        # This lets us substitute all parts of the go.mod that are dependent on
        # the layout of the filesystem with a structure we can reproduce (i.e.
        # no paths such as ../../../foo), run the Go tooling, then reverse the
        # process afterwards.
        def replace_directive_substitutions(manifest)
          @replace_directive_substitutions ||=
            (manifest["Replace"] || []).
            map { |r| r["New"]["Path"] }.
            compact.
            select { |p| stub_replace_path?(p) }.
            map { |p| [p, "./" + Digest::SHA2.hexdigest(p)] }.
            to_h
        end

        # returns true if the provided path should be replaced with a stub
        def stub_replace_path?(path)
          return true if absolute_path?(path)
          return false unless relative_replacement_path?(path)

          resolved_path = module_pathname.join(path).realpath
          inside_repo_contents_path = resolved_path.to_s.start_with?(repo_contents_path.to_s)
          !inside_repo_contents_path
        rescue Errno::ENOENT
          true
        end

        def absolute_path?(path)
          path.start_with?("/")
        end

        def relative_replacement_path?(path)
          # https://golang.org/ref/mod#go-mod-file-replace
          path.start_with?("./") || path.start_with?("../")
        end

        def module_pathname
          @module_pathname ||= Pathname.new(repo_contents_path).join(directory.sub(%r{^/}, ""))
        end

        def substitute_all(substitutions)
          body = substitutions.reduce(File.read("go.mod")) do |text, (a, b)|
            text.sub(a, b)
          end

          write_go_mod(body)
        end

        def handle_subprocess_error(stderr)
          stderr = stderr.gsub(Dir.getwd, "")

          # Package version doesn't match the module major version
          error_regex = RESOLVABILITY_ERROR_REGEXES.find { |r| stderr =~ r }
          if error_regex
            error_message = filter_error_message(message: stderr, regex: error_regex)
            raise Dependabot::DependencyFileNotResolvable, error_message
          end

          repo_error_regex = REPO_RESOLVABILITY_ERROR_REGEXES.find { |r| stderr =~ r }
          if repo_error_regex
            error_message = filter_error_message(message: stderr, regex: repo_error_regex)
            ResolvabilityErrors.handle(error_message, credentials: credentials)
          end

          path_regex = MODULE_PATH_MISMATCH_REGEXES.find { |r| stderr =~ r }
          if path_regex
            match = path_regex.match(stderr)
            raise Dependabot::GoModulePathMismatch.
              new(go_mod_path, match[1], match[2])
          end

          out_of_disk_regex = OUT_OF_DISK_REGEXES.find { |r| stderr =~ r }
          if out_of_disk_regex
            error_message = filter_error_message(message: stderr, regex: out_of_disk_regex)
            raise Dependabot::OutOfDisk.new, error_message
          end

          if (matches = stderr.match(/Authentication failed for '(?<url>.+)'/))
            raise Dependabot::PrivateSourceAuthenticationFailure, matches[:url]
          end

          # We don't know what happened so we raise a generic error
          msg = stderr.lines.last(10).join.strip
          raise Dependabot::DependabotError, msg
        end

        def filter_error_message(message:, regex:)
          lines = message.lines.select { |l| regex =~ l }
          return lines.join if lines.any?

          # In case the regex is multi-line, match the whole string
          message.match(regex).to_s
        end

        def go_mod_path
          return "go.mod" if directory == "/"

          File.join(directory, "go.mod")
        end

        def write_go_mod(body)
          File.write("go.mod", body)
        end

        def tidy?
          !!@tidy
        end

        def vendor?
          !!@vendor
        end
      end
    end
  end
end
