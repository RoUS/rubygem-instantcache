require 'rubygems'
gem('hoe', '>= 2.1.0')
require 'hoe'
require 'fileutils'
Proc.new {
  libdir = File.expand_path(File.join(File.dirname(__FILE__), 'lib'))
  $:.unshift(libdir) unless ($:.include?(libdir))
}.call
require 'instantcache'

Hoe.plugin(:newgem)
Hoe.plugin(:website)
# Hoe.plugin :cucumberfeatures

# Generate all the Rake tasks
# Run 'rake -T' to see list of generated tasks (from gem root directory)
$hoe = Hoe.spec('instantcache') {
  self.developer('Ken Coar',
                 'coar@rubyforge.org')
  #
  # TODO this is default value
  #
  self.rubyforge_name		= self.name
  self.version			= InstantCache::VERSION
  self.extra_deps		= [
                                   ['versionomy','>= 0.4.0']
                                  ]

}

require 'newgem/tasks'
Dir['tasks/**/*.rake'].each { |t| load t }

# TODO - want other tests/tasks run by default? Add them to the list
# remove_task :default
# task :default => [:spec, :features]
