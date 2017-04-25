source ENV['GEM_SOURCE'] || "https://rubygems.org"

def location_for(place, fake_version = nil)
  if place =~ /^(git[:@][^#]*)#(.*)/
    [fake_version, { :git => $1, :branch => $2, :require => false }].compact
  elsif place =~ /^file:\/\/(.*)/
    ['>= 0', { :path => File.expand_path($1), :require => false }]
  else
    [place, { :require => false }]
  end
end

group :test do
  gem 'redcarpet',                                                  :require => false
  gem 'rubocop', '~> 0.48.0',                                       :require => false if RUBY_VERSION >= '2.3.0'
  gem 'rubocop-rspec', '~> 1.15.0',                                 :require => false if RUBY_VERSION >= '2.3.0'
  gem 'mocha', '>= 1.2.1',                                          :require => false
  gem 'coveralls',                                                  :require => false
  gem 'simplecov-console',                                          :require => false
  gem 'github_changelog_generator', '~> 1.13.0',                    :require => false if RUBY_VERSION < '2.2.2'
  gem 'rack', '~> 1.0',                                             :require => false if RUBY_VERSION < '2.2.2'
  gem 'github_changelog_generator',                                 :require => false if RUBY_VERSION >= '2.2.2'
end

group :development do
  gem 'travis',                   :require => false
  gem 'travis-lint',              :require => false
  gem 'guard-rake',               :require => false
  gem 'overcommit', '~> 0.39.1',  :require => false
end

group :system_tests do
  gem 'serverspec',                    :require => false
  gem 'inspec',                        :require => false
end



if facterversion = ENV['FACTER_GEM_VERSION']
  gem 'facter', facterversion.to_s, :require => false, :groups => [:test]
else
  gem 'facter', :require => false, :groups => [:test]
end

ENV['PUPPET_VERSION'].nil? ? puppetversion = '~> 4.0' : puppetversion = ENV['PUPPET_VERSION'].to_s
gem 'puppet', puppetversion, :require => false, :groups => [:test]

gem 'slack'

# vim: syntax=ruby
