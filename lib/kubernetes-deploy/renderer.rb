# frozen_string_literal: true

require 'erb'
require 'securerandom'
require 'yaml'
require 'json'

module KubernetesDeploy
  class Renderer
    def initialize(current_sha:, template_dir:, logger:, bindings: {})
      @current_sha = current_sha
      @template_dir = template_dir
      @partials_dirs =
        %w(partials ../partials).map { |d| File.expand_path(File.join(@template_dir, d)) }
      @logger = logger
      @bindings = bindings
      # Max length of podname is only 63chars so try to save some room by truncating sha to 8 chars
      @id = current_sha[0...8] + "-#{SecureRandom.hex(4)}" if current_sha
    end

    def render_partial(partial, locals)
      variables = template_variables.merge("locals" => locals).merge(locals)
      path = find_partial(partial)
      src = render_template(File.basename(path), File.read(path), variables)
      # Make sure indentation isn't a problem, by producing a single line of
      # parseable YAML. Note that JSON is a subset of YAML.
      JSON.generate(YAML.load(src))
    rescue Psych::SyntaxError => e
      binding.pry
    end

    def render_template(filename, raw_template, variables = template_variables)
      return raw_template unless File.extname(filename) == ".erb"

      erb_binding = TemplateContext.new(self).template_binding
      bind_template_variables(erb_binding, variables)
      ERB.new(raw_template).result(erb_binding)
    rescue NameError => e
      @logger.summary.add_paragraph("Error from renderer:\n  #{e.message.tr("\n", ' ')}")
      raise FatalDeploymentError, "Template '#{filename}' cannot be rendered"
    end

    private

    def template_variables
      {
        'current_sha' => @current_sha,
        'deployment_id' => @id,
      }.merge(@bindings)
    end

    def bind_template_variables(binding, variables)
      variables.each do |var_name, value|
        binding.local_variable_set(var_name, value)
      end
    end

    def find_partial(name)
      partial_names = [name + '.yaml.erb', name + '.yml.erb']
      @partials_dirs.each do |dir|
        partial_names.each do |partial_name|
          partial_path = File.join(dir, partial_name)
          return partial_path if File.exist?(partial_path)
        end
      end
      raise FatalDeploymentError, "Could not find partial '#{name}' in any of #{@partials_dirs.join(':')}"
    end

    class TemplateContext
      attr_reader :template_binding

      def initialize(renderer)
        @_renderer = renderer
        @template_binding = binding
      end

      def partial(partial, locals = {})
        @_renderer.render_partial(partial, locals)
      end
    end
  end
end
