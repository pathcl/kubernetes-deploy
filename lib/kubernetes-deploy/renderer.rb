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

    def render_template(filename, raw_template, extra_variables = {})
      return raw_template unless File.extname(filename) == ".erb"

      erb_binding = TemplateContext.new(self).template_binding
      bind_template_variables(erb_binding, template_variables.merge(extra_variables))

      ERB.new(raw_template, nil, '-').result(erb_binding)
    rescue NameError, Psych::SyntaxError => e
      report_template_invalid!(e, filename, raw_template)
    end

    def render_partial(partial, locals)
      template_file = find_partial(partial)
      content = File.read(template_file)
      variables = { locals: locals }.merge(locals)
      expanded_template = render_template(template_file, content, variables)

      docs = YAML.load_stream(expanded_template)
      return JSON.generate(docs.first) if docs.one?

      docs.map do |doc|
        "\n---\n" + JSON.generate(doc)
      end.join
    rescue NameError, Psych::SyntaxError => e
      report_template_invalid!(e, template_file, expanded_template)
    end

    private

    def report_template_invalid!(err, filename, content)
      @logger.summary.add_paragraph("Error from renderer:\n  #{err.message.tr("\n", ' ')}")
      @logger.summary.add_paragraph("Rendered template content:\n#{content}")
      raise FatalDeploymentError, "Template '#{filename}' cannot be rendered"
    end

    def template_variables
      {
        'current_sha' => @current_sha,
        'deployment_id' => @id,
      }.merge(@bindings)
    end

    def bind_template_variables(erb_binding, variables)
      variables.each do |var_name, value|
        erb_binding.local_variable_set(var_name, value)
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
      def initialize(renderer)
        @_renderer = renderer
      end

      def template_binding
        binding
      end

      def partial(partial, locals = {})
        @_renderer.render_partial(partial, locals)
      end
    end
  end
end
