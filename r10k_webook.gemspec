#coding: utf-8
require File.expand_path('../lib/puppet_webhook/version', __FILE__)

GEM_FILES = [

]

Gem::Specification.new do |spec|
  spec.name        = 'puppet_webhook'
  spec.version     = Puppet::Webhook::VERSION
  spec.platform    = Gem::Platform::RUBY
  spec.author      = ['Vox Pupuli']
  spec.email       = ['support@voxpupuli.org']
  spec.summary     = 'Sinatra-based webhook for use with Puppet'
  spec.description = 'Sinatra-based webhook for use with Puppet. This webhook
                        contains default endpoints for deploying environments
                        and modules with r10k, but can be extended to include
                        additional endpoints.'
  spec.licenses    = 'Apache-2.0'
end
