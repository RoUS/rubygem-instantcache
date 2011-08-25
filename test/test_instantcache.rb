require File.dirname(__FILE__) + '/test_helper.rb'
require 'ruby-debug'
Debugger.start

class TestInstantCache < Test::Unit::TestCase

  TestClass_def = <<-'EOT'
    class TestClass
      include InstantCache
      memcached_accessor(:mca)
      memcached_reader(:mcr)
      memcached_counter(:mcc)
    end
  EOT

  def setup
    if (InstantCache.cache_object.nil?)
      InstantCache.cache_object = MemCache.new('127.0.0.1:11211')
    end
    if (self.class.const_defined?(:TestClass))
      self.class.class_eval('remove_const(:TestClass)')
    end
    self.class.class_eval(TestClass_def)
  end
  
  def test_01_new_and_empty
    test_obj = TestClass.new
    assert_nil(test_obj.mca)
    assert_nil(test_obj.mcr)
    assert_equal(0, test_obj.mcc)
  end

end
