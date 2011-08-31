Proc.new {
  libdir = File.expand_path(File.join(File.dirname(__FILE__), '..', 'lib'))
  $:.unshift(libdir) unless ($:.include?(libdir))
}.call
require 'rubygems'
require 'stringio'
require 'test/unit'
require 'instantcache'
