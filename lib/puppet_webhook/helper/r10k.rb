require 'puppet_webhook/config'


module Puppet
  module Webhook
    module R10kHelpers

      # Ignore environments that we don't care about e.g. feature or bugfix branches
      def ignore_env?(env)
        list = $config['ignore_environments']
        return false if list.nil? or list.empty?

        list.each do |l|
          # Even unquoted array elements wrapped by slashes becomes strings after YAML parsing
          # So we need to convert it into Regexp manually
          if l =~ /^\/.+\/$/
            return true if env =~ Regexp.new(l[1..-2])
          else
            return true if env == l
          end
        end

        return false
      end

      # Check to see if this is an event we care about. Default to responding to all events
      def ignore_event?
        # Explicitly ignore GitHub ping events
        return true if request.env['HTTP_X_GITHUB_EVENT'] == 'ping'

        list  = $config['repository_events']
        event = request.env['HTTP_X_GITHUB_EVENT']

        # negate this, because we should respond if any of these conditions are true
        ! (list.nil? or list == event or list.include?(event))
      end

      def run_command(command)
        message = ''
        File.open(LOCKFILE, 'w+') do |file|
          # r10k has a small race condition which can cause failed deploys if two happen
          # more or less simultaneously. To mitigate, we just lock on a file and wait for
          # the other one to complete.
          file.flock(File::LOCK_EX)

          if Open3.respond_to?('capture3')
            stdout, stderr, exit_status = Open3.capture3(command)
            message = "triggered: #{command}\n#{stdout}\n#{stderr}"
          else
            message = "forked: #{command}"
            Process.detach(fork{ exec "#{command} &"})
            exit_status = 0
          end
          raise "#{stdout}\n#{stderr}" if exit_status != 0
        end
        message
      end

      def notify_slack(status_message)
        if $config['slack_channel']
          slack_channel = $config['slack_channel']
        else
          slack_channel = '#default'
        end

        if $config['slack_username']
          slack_user = $config['slack_username']
        else
          slack_user = 'r10k'
        end

        notifier = Slack::Notifier.new $config['slack_webhook'] do
          defaults channel: slack_channel,
                   username: slack_user,
                   icon_emoji: ":ocean:"
        end

        if status_message[:branch]
          target = status_message[:branch]
        elsif status_message[:module]
          target = status_message[:module]
        end

        message = {
            author: 'r10k for Puppet',
            title: "r10k deployment of Puppet environment #{target}"
        }

        case status_message[:status_code]
          when 200
            message.merge!(
                color: "good",
                text: "Successfully deployed #{target}",
                fallback: "Successfully deployed #{target}"
            )
          when 500
            message.merge!(
                color: "bad",
                text: "Failed to deploy #{target}",
                fallback: "Failed to deploy #{target}"
            )
        end

        notifier.post text: message[:fallback], attachments: [message]
      end

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

      def protected!
        unless authorized?
          response['WWW-Authenticate'] = %(Basic realm="Restricted Area")
          $logger.error("Authentication failure from IP #{request.ip}")
          throw(:halt, [401, "Not authorized\n"])
        else
          $logger.info("Authenticated as user #{$config['user']} from IP #{request.ip}")
        end
      end  #end protected!

      def authorized?
        @auth ||=  Rack::Auth::Basic::Request.new(request.env)
        @auth.provided? && @auth.basic? && @auth.credentials &&
            @auth.credentials == [$config['user'],$config['pass']]
      end  #end authorized?

      def slack?
        !!$config['slack_webhook']
      end

      def verify_signature(payload_body)
        signature = 'sha1=' + OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new('sha1'), $config['github_secret'], payload_body)
        throw(:halt, [500, "Signatures didn't match!\n"]) unless Rack::Utils.secure_compare(signature, request.env['HTTP_X_HUB_SIGNATURE'])
      end

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

      def run_prefix_command(payload)
        IO.popen($config['prefix_command'], mode='r+') do |io|
          io.write payload.to_s
          io.close_write
          begin
            result = io.readlines.first.chomp
          rescue
            result = ''
          end
        end
      end #end run_prefix_command


      # :deploy and :deploy_module methods are vulnerable to shell
      # injection. e.g. a branch named ";yes". Or a malicious POST request with
      # "; rm -rf *;" as the payload.
      def sanitize_input(input_string)
        sanitized = Shellwords.shellescape(input_string)
        $logger.info("module or branch name #{sanitized} had to be escaped!") unless input_string == sanitized
        sanitized
      end

    end
  end
end