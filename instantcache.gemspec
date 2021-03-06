# -*- encoding: utf-8 -*-

Gem::Specification.new do |s|
  s.name = "instantcache"
  s.version = "0.1.1"

  s.required_rubygems_version = Gem::Requirement.new(">= 1.3.1") if s.respond_to? :required_rubygems_version=
  s.authors = ["Ken Coar"]
  s.date = "2011-09-09"
  s.description = "rubygem-instantcache provides the InstantCache module, a mixin\nwhich has accessors that allow you to declare 'instance variables'\nthat are actually stored in a memcached cluster rather than\nlocal memory."
  s.email = ["coar@rubyforge.org"]
  s.extra_rdoc_files = ["History.txt", "LICENCE.txt", "Manifest.txt", "README.txt"]
  s.files = ["History.txt", "LICENCE.txt", "Manifest.txt", "README.txt", "Rakefile", "instantcache.gemspec", "lib/instantcache.rb", "lib/instantcache/exceptions.rb", "script/console", "script/destroy", "script/generate", "test/test_helper.rb", "test/test_instantcache.rb", "test/test_sharing_complex.rb", "test/test_sharing_simple.rb", ".gemtest"]
  s.homepage = "http://instantcache.rubyforge.org/"
  s.rdoc_options = ["--main", "README.txt"]
  s.require_paths = ["lib"]
  s.rubyforge_project = "instantcache"
  s.rubygems_version = "1.8.10"
  s.summary = "rubygem-instantcache provides the InstantCache module, a mixin which has accessors that allow you to declare 'instance variables' that are actually stored in a memcached cluster rather than local memory."
  s.test_files = ["test/test_instantcache.rb", "test/test_helper.rb", "test/test_sharing_simple.rb", "test/test_sharing_complex.rb"]

  if s.respond_to? :specification_version then
    s.specification_version = 3

    if Gem::Version.new(Gem::VERSION) >= Gem::Version.new('1.2.0') then
      s.add_runtime_dependency(%q<versionomy>, [">= 0.4.0"])
      s.add_runtime_dependency(%q<memcache-client>, [">= 1.8.5"])
      s.add_development_dependency(%q<hoe>, ["~> 2.12"])
    else
      s.add_dependency(%q<versionomy>, [">= 0.4.0"])
      s.add_dependency(%q<memcache-client>, [">= 1.8.5"])
      s.add_dependency(%q<hoe>, ["~> 2.12"])
    end
  else
    s.add_dependency(%q<versionomy>, [">= 0.4.0"])
    s.add_dependency(%q<memcache-client>, [">= 1.8.5"])
    s.add_dependency(%q<hoe>, ["~> 2.12"])
  end
end
