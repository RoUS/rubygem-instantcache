require File.dirname(__FILE__) + '/test_helper.rb'
require 'ruby-debug'
Debugger.start

class TestInstantCache < Test::Unit::TestCase

  TestClass1_def = <<-'EOT'
    class TestClass1
      include InstantCache
      memcached_accessor(:mca)
      memcached_reader(:mcr)
      memcached_counter(:mcc)
    end
  EOT

  TestClass2_def = <<-'EOT'
    class TestClass2
      include InstantCache
      memcached_accessor(:mca)	{ |ivar| "test-#{ivar.to_s}" }
      memcached_reader(:mcr)	{ |ivar| "test-#{ivar.to_s}" }
      memcached_counter(:mcc)	{ |ivar| "test-#{ivar.to_s}" }
    end
  EOT

  def setup
    if (InstantCache.cache_object.nil?)
      InstantCache.cache_object = MemCache.new('127.0.0.1:11211')
    end
    if (self.class.const_defined?(:TestClass1))
      self.class.class_eval('remove_const(:TestClass1)')
    end
    if (self.class.const_defined?(:TestClass2))
      self.class.class_eval('remove_const(:TestClass2)')
    end
    self.class.class_eval(TestClass1_def)
    self.class.class_eval(TestClass2_def)
  end
  
  def test_01_new_and_empty
    test_obj = TestClass1.new
    assert_nil(test_obj.mca)
    assert_nil(test_obj.mcr)
    assert_equal(0, test_obj.mcc)
  end

  def test_02_test_default_names
    test_obj = TestClass1.new
    assert_nil(test_obj.mca)
    assert_nil(test_obj.mcr)
    assert_equal(0, test_obj.mcc)
    [ 'mca', 'mcr', 'mcc' ].each do |ivar|
      expected = '%s:%d:@%s' % [ test_obj.class.name, test_obj.object_id, ivar ]
      test_val = test_obj.instance_variable_get("@#{ivar}".to_sym).name
      assert_equal(expected, test_val)
    end
  end

  def test_03_test_custom_names
    test_obj = TestClass2.new
    assert_nil(test_obj.mca)
    assert_nil(test_obj.mcr)
    assert_equal(0, test_obj.mcc)
    [ 'mca', 'mcr', 'mcc' ].each do |ivar|
      expected = 'test-%s' % [ ivar ]
      test_val = test_obj.instance_variable_get("@#{ivar}".to_sym).name
      assert_equal(expected, test_val)
    end
  end

end
