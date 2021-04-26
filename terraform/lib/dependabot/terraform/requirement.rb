# frozen_string_literal: true

require "dependabot/utils"
require "dependabot/terraform/version"

# Just ensures that Terraform requirements use Terraform versions
module Dependabot
  module Terraform
    class Requirement < Gem::Requirement
      def self.parse(obj)
        return ["=", Version.new(obj.to_s)] if obj.is_a?(Gem::Version)

        unless (matches = PATTERN.match(obj.to_s))
          msg = "Illformed requirement [#{obj.inspect}]"
          raise BadRequirementError, msg
        end

        return DefaultRequirement if matches[1] == ">=" && matches[2] == "0"

        [matches[1] || "=", Terraform::Version.new(matches[2])]
      end

      # For consistency with other langauges, we define a requirements array.
      # Terraform doesn't have an `OR` separator for requirements, so it
      # always contains a single element.
      def self.requirements_array(requirement_string)
        [new(requirement_string)]
      end

      # Patches Gem::Requirement to make it accept requirement strings like
      # "~> 4.2.5, >= 4.2.5.1" without first needing to split them.
      def initialize(*requirements)
        requirements = requirements.flatten.flat_map do |req_string|
          req_string.split(",").map(&:strip)
        end

        super(requirements)
      end
    end
  end
end

Dependabot::Utils.
  register_requirement_class("terraform", Dependabot::Terraform::Requirement)
