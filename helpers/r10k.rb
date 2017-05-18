module WebhookR10k
  def deploy_module(module_name)
    begin
      if $config['use_mcollective']
        command = "#{$command_prefix} mco r10k deploy_module #{module_name} #{$config['mco_arguments']}"
      else
        # If you don't use mcollective then this hook needs to be running as r10k's user i.e. root
        command = "#{$command_prefix} r10k deploy module #{module_name}"
      end
      message = run_command(command)
      $logger.info("message: #{message} module_name: #{module_name}")
      status_message = {:status => :success, :message => message.to_s, :module_name => module_name, :status_code => 200}
      notify_slack(status_message) if slack?
      status_message.to_json
    rescue => e
      $logger.error("message: #{e.message} trace: #{e.backtrace}")
      status 500
      status_message = {:status => :fail, :message => e.message, :trace => e.backtrace, :module_name => module_name, :status_code => 500}
      notify_slack(status_message) if slack?
      status_message.to_json
    end
  end

  def deploy(branch)
    begin
      if $config['use_mco_ruby']
        result = mco(branch).first
        if result.results[:statuscode] == 0
          message = result.results[:statusmsg]
        else
          raise result.results[:statusmsg]
        end
      else
        if $config['use_mcollective']
          command = "#{$command_prefix} mco r10k deploy #{branch} #{$config['mco_arguments']}"
        else
          # If you don't use mcollective then this hook needs to be running as r10k's user i.e. root
          command = "#{$command_prefix} r10k deploy environment #{branch} #{$config['r10k_deploy_arguments']}"
        end
        message = run_command(command)
      end
      status_message =  {:status => :success, :message => message.to_s, :branch => branch, :status_code => 200}
      $logger.info("message: #{message} branch: #{branch}")
      notify_slack(status_message) if slack?
      status_message.to_json
    rescue => e
      status_message = {:status => :fail, :message => e.message, :trace => e.backtrace, :branch => branch, :status_code => 500}
      $logger.error("message: #{e.message} trace: #{e.backtrace}")
      status 500
      notify_slack(status_message) if slack?
      status_message.to_json
    end
  end  #end deploy()

  def mco(branch)
    options =  MCollective::Util.default_options
    options[:config] = $config['client_cfg']
    client = rpcclient('r10k', :exit_on_failure => false,:options => options)
    client.discovery_timeout = $config['discovery_timeout']
    client.timeout           = $config['client_timeout']
    result = client.send('deploy',{:environment => branch})
  end # end mco()

  def repo_name(data)
    # Tested with GitHub only
    data['repository']['name'] rescue nil
  end

  def repo_user(data)
    # Tested with GitHub only
    data['repository']['owner']['login'] rescue nil
  end

  def normalize(str)
    # one could argue that r10k should do this along with the other normalization it does...
    $config['allow_uppercase'] ? str : str.downcase
  end

end