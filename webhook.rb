#!/opt/puppetlabs/puppet/bin/ruby
# This mini-webserver is meant to be run as the peadmin user
# so that it can call mcollective from a puppetmaster
# Authors:
# Ben Ford
# Adam Crews
# Zack Smith
# Jeff Malnick

require 'sinatra/base'
require 'openssl'
require 'resolv'
require 'json'
require 'yaml'
require 'cgi'

class Webhook < Sinatra::Base

  set :static, false
  if $config['enable_mutex_lock'] then
    set :lock,   true
  end

end

require_relative 'helpers/init'
require_relative 'routes/init'