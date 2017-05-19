require 'open3'
require 'openssl'
require 'rack'
require 'shellwords'

module WebhookMain
  @config = WEBHOOK_CONFIG
  # Ignore environments that we don't care about e.g. feature or bugfix branches
  def ignore_env?(env)
    list = @config['ignore_environments']
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

    list  = @config['repository_events']
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

  def protected!
    unless authorized?
      response['WWW-Authenticate'] = %(Basic realm="Restricted Area")
      $logger.error("Authentication failure from IP #{request.ip}")
      throw(:halt, [401, "Not authorized\n"])
    else
      $logger.info("Authenticated as user #{@config['user']} from IP #{request.ip}")
    end
  end  #end protected!

  def authorized?
    @auth ||=  Rack::Auth::Basic::Request.new(request.env)
    @auth.provided? && @auth.basic? && @auth.credentials &&
        @auth.credentials == [@config['user'],@config['pass']]
  end  #end authorized?

  def verify_signature(payload_body)
    signature = 'sha1=' + OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new('sha1'), @config['github_secret'], payload_body)
    throw(:halt, [500, "Signatures didn't match!\n"]) unless Rack::Utils.secure_compare(signature, request.env['HTTP_X_HUB_SIGNATURE'])
  end

  def run_prefix_command(payload)
    IO.popen(@config['prefix_command'], mode='r+') do |io|
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