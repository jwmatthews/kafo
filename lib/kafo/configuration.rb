# encoding: UTF-8
require 'yaml'
require 'tmpdir'
require 'kafo/puppet_module'
require 'kafo/password_manager'

module Kafo
  class Configuration
    attr_reader :config_file, :answer_file

    def self.colors_possible?
      !`which tput 2> /dev/null`.empty? && `tput colors`.to_i > 0
    end

    DEFAULT = {
        :name                 => '',
        :description          => '',
        :log_dir              => '/var/log/kafo',
        :log_name             => 'configuration.log',
        :log_level            => 'info',
        :no_prefix            => false,
        :mapping              => {},
        :answer_file          => './config/answers.yaml',
        :installer_dir        => '.',
        :module_dirs          => ['./modules'],
        :default_values_dir   => '/tmp',
        :colors               => Configuration.colors_possible?,
        :color_of_background  => :dark,
        :hook_dirs            => [],
        :custom               => {},
        :low_priority_modules => [],
    }

    def initialize(file, persist = true)
      @config_file = file
      @persist     = persist
      configure_application
      @logger = KafoConfigure.logger

      @answer_file = app[:answer_file]
      begin
        @data = YAML.load_file(@answer_file)
      rescue Errno::ENOENT => e
        puts "No answer file at #{@answer_file} found, can not continue"
        KafoConfigure.exit(:no_answer_file)
      end

      @config_dir = File.dirname(@config_file)
    end

    def save_configuration(configuration)
      return true unless @persist
      FileUtils.touch @config_file
      File.chmod 0600, @config_file
      File.open(@config_file, 'w') { |file| file.write(format(YAML.dump(configuration))) }
    end

    def configure_application
      result = app
      save_configuration(result)
      result
    end

    def app
      @app ||= begin
        begin
          configuration = YAML.load_file(@config_file)
        rescue => e
          configuration = {}
        end

        result            = DEFAULT.merge(configuration || {})
        result[:password] ||= PasswordManager.new.password
        result
      end
    end

    def get_custom(key)
      custom_storage[key.to_sym]
    end

    def set_custom(key, value)
      custom_storage[key.to_sym] = value
    end

    def modules
      @modules ||= @data.keys.map { |mod| PuppetModule.new(mod).parse }.sort
    end

    def add_module(name)
      mod = PuppetModule.new(name).parse
      unless modules.map(&:name).include?(mod.name)
        mod.enable
        @modules << mod
      end
    end

    def add_mapping(module_name, mapping)
      app[:mapping][module_name] = mapping
      save_configuration(app)
    end

    def params_default_values
      @params_default_values ||= begin
        @logger.debug "Creating tmp dir within #{app[:default_values_dir]}..."
        temp_dir = Dir.mktmpdir(nil, app[:default_values_dir])
        KafoConfigure.exit_handler.register_cleanup_path temp_dir
        @logger.info 'Loading default values from puppet modules...'
        command = PuppetCommand.new("$temp_dir=\"#{temp_dir}\" #{includes} dump_values(#{params_to_dump})", ['--noop']).append('2>&1').command
        result = `#{command}`
        @logger.debug result
        unless $?.exitstatus == 0
          log = app[:log_dir] + '/' + app[:log_name]
          puts "Could not get default values, check log file at #{log} for more information"
          @logger.error command
          @logger.error result
          @logger.error 'Could not get default values, cannot continue'
          KafoConfigure.exit(:defaults_error)
        end
        @logger.info "... finished"
        YAML.load_file(File.join(temp_dir, 'default_values.yaml'))
      end
    end

    # if a value is a true we return empty hash because we have no specific options for a
    # particular puppet module
    def [](key)
      value = @data[key]
      value.is_a?(Hash) ? value : {}
    end

    def module_enabled?(mod)
      value = @data[mod.is_a?(String) ? mod : mod.identifier]
      !!value || value.is_a?(Hash)
    end

    def config_header
      files          = [app[:config_header_file], File.join(KafoConfigure.gem_root, '/config/config_header.txt')].compact
      file           = files.select { |f| File.exists?(f) }.first
      @config_header ||= file.nil? ? '' : File.read(file)
    end

    def store(data, file = nil)
      filename = file || answer_file
      FileUtils.touch filename
      File.chmod 0600, filename
      File.open(filename, 'w') { |file| file.write(config_header + format(YAML.dump(data))) }
    end

    def params
      @params ||= modules.map(&:params).flatten
    end

    def preset_parameters
      # set values based on default_values
      params.each do |param|
        param.set_default(params_default_values)
      end

      # set values based on YAML
      params.each do |param|
        param.set_value_by_config(self)
      end
      params
    end

    private

    def custom_storage
      app[:custom]
    end

    def includes
      modules.map do |mod|
        module_dir = KafoConfigure.module_dirs.find do |dir|
          params_file = File.join(dir, mod.params_path)
          @logger.debug "checking presence of #{params_file}"
          File.exist?(params_file)
        end
        module_dir ? "include #{mod.dir_name}::#{mod.params_class_name}" : nil
      end.uniq.compact.join(' ')
    end

    def params_to_dump
      parameters = params.select { |p| p.default != 'UNSET' }
      parameters.map { |param| "#{param.dump_default}" }.join(',')
    end

    def format(data)
      data.gsub('!ruby/sym ', ':')
    end
  end
end
