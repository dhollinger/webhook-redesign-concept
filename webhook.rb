# This mini-webserver is meant to be run as the peadmin user
# so that it can call mcollective from a puppetmaster
# Authors:
# Ben Ford
# Adam Crews
# Zack Smith
# Jeff Malnick

require 'rubygems'
require 'sinatra/base'
require 'webrick'
require 'webrick/https'
require 'openssl'
require 'resolv'
require 'json'
require 'yaml'
require 'cgi'
require 'open3'
require 'shellwords'

WEBHOOK_CONFIG = '/etc/webhook.yaml'
PIDFILE        = '/var/run/webhook/webhook.pid'
LOCKFILE       = '/var/run/webhook/webhook.lock'
APP_ROOT       = '/var/run/webhook'
EXTENSION_DIR  = '/etc/webhook'

if (File.exists?(WEBHOOK_CONFIG))
  $config = YAML.load_file(WEBHOOK_CONFIG)
else
  raise "Configuration file: #{WEBHOOK_CONFIG} does not exist"
end

if $config['home']
  ENV['HOME'] = $config['home']
end

ENV['PATH'] = '/sbin:/usr/sbin:/bin:/usr/bin:/opt/puppetlabs/puppet/bin:/opt/puppet/bin:/usr/local/bin'

$logger = WEBrick::Log::new($config['access_logfile'], WEBrick::Log::DEBUG)



opts = {
  :Host           => $config['bind_address'],
  :Port           => $config['port'],
  :Logger         => $logger,
  :ServerType     => $config['server_type'],
  :ServerSoftware => $config['server_software'],
  :SSLEnable      => $config['enable_ssl'],
  :StartCallback  => Proc.new { File.open(PIDFILE, 'w') {|f| f.write Process.pid } },
}
if $config['enable_ssl'] then
  opts[:SSLVerifyClient] = OpenSSL::SSL::VERIFY_NONE
  opts[:SSLCertificate]  = OpenSSL::X509::Certificate.new(File.open("#{$config['public_key_path']}").read)
  opts[:SSLPrivateKey]   = OpenSSL::PKey::RSA.new(File.open("#{$config['private_key_path']}").read)
  opts[:SSLCertName]     = [ [ "CN",WEBrick::Utils::getservername ] ]
end

if $config['use_mcollective'] then
  require 'mcollective'
  include MCollective::RPC
end

if $config['slack_webhook'] then
  require 'slack-notifier'
end

$command_prefix = $config['command_prefix'] || ''

class Server < Sinatra::Base

  set :static, false
  if $config['enable_mutex_lock'] then
    set :lock,   true
  end

  get '/' do
    raise Sinatra::NotFound
  end

  get '/heartbeat' do
    return 200,  {:status => :success, :message => 'running' }.to_json
  end

  # Simulate a github post:
  # curl -d '{ "repository": { "name": "puppetlabs-stdlib" } }' -H "Accept: application/json" 'https://puppet:487156B2-7E67-4E1C-B447-001603C6B8B2@localhost:8088/module' -k -q
  #
  # Simulate a BitBucket post:
  # curl -X POST -d '{ "repository": { "full_name": "puppetlabs/puppetlabs-stdlib", "name": "PuppetLabs : StdLib" } }' 'https://puppet:puppet@localhost:8088/module' -k -q
  # This example shows that, unlike github, BitBucket allows special characters
  # in repository names but translates it to generate a full_name which
  # is used in the repository URL and is most useful for this webhook handler.
  post '/module' do
    protected! if $config['protected']
    request.body.rewind  # in case someone already read it

    # Short circuit if we're ignoring this event
    return 200 if ignore_event?

    decoded = request.body.read
    verify_signature(decoded) if $config['github_secret']
    data    = JSON.parse(decoded, :quirks_mode => true)

    if data['repository'].has_key?('full_name')
      # handle BitBucket webhook...
      module_name = ( data['repository']['full_name'] ).sub(/^.*\/.*-/, '')
    else
      module_name = ( data['repository']['name'] ).sub(/^.*-/, '')
    end

    module_name = sanitize_input(module_name)
    deploy_module(module_name)
  end

  # Simulate a github post:
  # curl -d '{ "ref": "refs/heads/production" }' -H "Accept: application/json" 'https://puppet:puppet@localhost:8088/payload' -k -q
  #
  # If using stash look at the stash_mco.rb script included here.
  # It will filter the stash post and make it look like a github post.
  #
  # Simulate a Gitorious post:
  # curl -X POST -d '%7b%22ref%22%3a%22master%22%7d' 'http://puppet:puppet@localhost:8088/payload' -q
  # Yes, Gitorious does not support https...
  #
  # Simulate a BitBucket post:
  # curl -X POST -d '{ "push": { "changes": [ { "new": { "name": "production" } } ] } }' 'https://puppet:puppet@localhost:8088/payload' -k -q

  post '/payload' do
    protected! if $config['protected']
    request.body.rewind  # in case someone already read it

    # Short circuit if we're ignoring this event
    return 200 if ignore_event?

    # Check if content type is x-www-form-urlencoded
    if request.content_type.to_s.downcase.eql?('application/x-www-form-urlencoded')
      decoded = CGI::unescape(request.body.read).gsub(/^payload\=/,'')
    else
      decoded = request.body.read
    end
    verify_signature(decoded) if $config['github_secret']
    data = JSON.parse(decoded, :quirks_mode => true)

    # Iterate the data structure to determine what's should be deployed
    branch = (
        data['ref']                                          ||  # github & gitlab
        data['refChanges'][0]['refId']            rescue nil ||  # stash
        data['push']['changes'][0]['new']['name'] rescue nil ||  # bitbucket
        data['resource']['refUpdates'][0]['name'] rescue nil ||  # TFS/VisualStudio-Git
        data['repository']['default_branch']                     # github tagged release; no ref.
      ).sub('refs/heads/', '') rescue nil

    # If prefix is enabled in our config file, determine what the prefix should be
    prefix = case $config['prefix']
    when :repo
      repo_name(data)
    when :user
      repo_user(data)
    when :command, TrueClass
      run_prefix_command(data.to_json)
    when String
      $config['prefix']
    end

    branch = sanitize_input(branch)
    # r10k doesn't yet know how to deploy all branches from a single source.
    # The best we can do is just deploy all environments by passing nil to
    # deploy() if we don't know the correct branch.
    if prefix.nil? or prefix.empty? or branch.nil? or branch.empty?
      env = normalize(branch)
    else
      env = normalize("#{prefix}_#{branch}")
    end

    if ignore_env?(env)
      $logger.info("Skipping deployment of environment #{env} according to ignore_environments configuration parameter")
      return 200
    else
      deploy(env)
    end
  end

  not_found do
    halt 404, "You shall not pass! (page not found)\n"
  end

  helpers do

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

  end  #end helper
end

Rack::Handler::WEBrick.run(Server, opts) do |server|
  [:INT, :TERM].each { |sig| trap(sig) { server.stop } }
end
