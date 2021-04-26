# frozen_string_literal: true

module Dependabot
  module Config
    # Filters versions that should not be considered for dependency updates
    class IgnoreCondition
      PATCH_VERSION_TYPE = "version-update:semver-patch"
      MINOR_VERSION_TYPE = "version-update:semver-minor"
      MAJOR_VERSION_TYPE = "version-update:semver-major"

      ALL_VERSIONS = ">= 0"

      attr_reader :dependency_name, :versions, :update_types

      def initialize(dependency_name:, versions: nil, update_types: nil)
        @dependency_name = dependency_name
        @versions = versions || []
        @update_types = update_types || []
      end

      def ignored_versions(dependency, security_updates_only)
        return versions if security_updates_only
        return [ALL_VERSIONS] if versions.empty? && transformed_update_types.empty?

        versions_by_type(dependency) + versions
      end

      private

      def transformed_update_types
        update_types.map(&:downcase).map(&:strip).compact
      end

      def versions_by_type(dependency)
        transformed_update_types.flat_map do |t|
          case t
          when PATCH_VERSION_TYPE
            ignore_patch(dependency.version)
          when MINOR_VERSION_TYPE
            ignore_minor(dependency.version)
          when MAJOR_VERSION_TYPE
            ignore_major(dependency.version)
          else
            []
          end
        end.compact
      end

      def ignore_patch(version)
        parts = version.split(".")
        return [] unless parts.size > 2

        lower_parts = parts.first(2) + ["a"]
        upper_parts = parts.first(2)
        upper_parts[1] = upper_parts[1].to_i + 1
        lower_bound = ">= #{lower_parts.join('.')}"
        upper_bound = "< #{upper_parts.join('.')}"
        ["#{lower_bound}, #{upper_bound}"]
      end

      def ignore_minor(version)
        parts = version.split(".")
        return [] if parts.size < 2

        if Gem::Version.correct?(version)
          lower_parts = parts.first(2) + ["a"]
          upper_parts = parts.first(1)
          lower_parts[1] = lower_parts[1].to_i + 1
          upper_parts[0] = upper_parts[0].to_i + 1
        else
          lower_parts = parts.first(1) + ["a"]
          upper_parts = parts.first(1)
          begin
            upper_parts[0] = Integer(upper_parts[0]) + 1
          rescue ArgumentError
            upper_parts.push(999_999)
          end
        end

        lower_bound = ">= #{lower_parts.join('.')}"
        upper_bound = "< #{upper_parts.join('.')}"
        ["#{lower_bound}, #{upper_bound}"]
      end

      def ignore_major(version)
        parts = version.split(".")
        return [] unless parts.size > 1

        lower_parts = parts.first(1) + ["a"]
        upper_parts = parts.first(1)
        lower_parts[0] = lower_parts[0].to_i + 1
        upper_parts[0] = upper_parts[0].to_i + 2
        lower_bound = ">= #{lower_parts.join('.')}"
        upper_bound = "< #{upper_parts.join('.')}"

        ["#{lower_bound}, #{upper_bound}"]
      end
    end
  end
end
