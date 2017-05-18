root = ::File.dirname(__FILE__)
require ::File.join(root, 'webhook_old.rb')
require 'rack'
require 'webrick'
require 'webrick/https'
require 'yaml'
require 'openssl'

WEBHOOK_CONFIG = './webhook.yaml'
PIDFILE        = '/var/run/webhook/webhook.pid'
LOCKFILE       = '/var/run/webhook/webhook.lock'
APP_ROOT       = '/var/run/webhook'

if File.exists?(WEBHOOK_CONFIG)
  $config = YAML.load_file(WEBHOOK_CONFIG)
else
  raise "Configuration file: #{WEBHOOK_CONFIG} does not exist"
end

ENV['PATH'] = '/sbin:/usr/sbin:/bin:/usr/bin:/opt/puppetlabs/puppet/bin:/usr/local/bin'

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
if $config['enable_ssl']
  opts[:SSLVerifyClient] = OpenSSL::SSL::VERIFY_NONE
  opts[:SSLCertificate]  = OpenSSL::X509::Certificate.new(File.open("#{$config['public_key_path']}").read)
  opts[:SSLPrivateKey]   = OpenSSL::PKey::RSA.new(File.open("#{$config['private_key_path']}").read)
  opts[:SSLCertName]     = [ [ "CN",WEBrick::Utils::getservername ] ]
end

if $config['use_mcollective']
  require 'mcollective'
  include MCollective::RPC
end

if $config['slack_webhook']
  require 'slack-notifier'
end

$command_prefix = $config['command_prefix'] || ''

Rack::Handler::WEBrick.run(Webhook, opts) do |server|
  [:INT, :TERM].each { |sig| trap(sig) { server.stop } }
end