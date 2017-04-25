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
