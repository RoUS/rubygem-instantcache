require File.dirname(__FILE__) + '/test_helper.rb'
require 'thread'
require 'ruby-debug'
Debugger.start

class TestInstantCache_02 < Test::Unit::TestCase

  class << self

    def ivar2name(ivar)
      return 'test-' + ivar.to_s
    end

  end

  TestClass_def = <<-'EOT'
    class TestClass
      include InstantCache
      memcached_accessor(:umca)	{ |ivar| "test-#{ivar.to_s}" }
      memcached_reader(:umcr)	{ |ivar| "test-#{ivar.to_s}" }
      memcached_counter(:umcc)	{ |ivar| "test-#{ivar.to_s}" }
      memcached_accessor(InstantCache::PRIVATE, :pmca) \
				{ |ivar| "test-#{ivar.to_s}" }
      memcached_reader(InstantCache::PRIVATE, :pmcr) \
				{ |ivar| "test-#{ivar.to_s}" }
      memcached_counter(InstantCache::PRIVATE, :pmcc) \
				{ |ivar| "test-#{ivar.to_s}" }
      memcached_accessor(InstantCache::SHARED, :smca) \
				{ |ivar| "test-#{ivar.to_s}" }
      memcached_reader(InstantCache::SHARED, :smcr) \
				{ |ivar| "test-#{ivar.to_s}" }
      memcached_counter(InstantCache::SHARED, :smcc) \
				{ |ivar| "test-#{ivar.to_s}" }
    end
  EOT

  VARS = %w( umca umcr umcc pmca pmcr pmcc smca smcr smcc )

  def setup
    if (InstantCache.cache_object.nil?)
      InstantCache.cache_object = MemCache.new('127.0.0.1:11211')
    end
    if (self.class.const_defined?(:TestClass))
      self.class.class_eval('remove_const(:TestClass)')
    end
    self.class.class_eval(TestClass_def)
  end

  def teardown
    unless (self.class.const_defined?(:TestClass))
      self.class.class_eval(TestClass_def)
    end
    cleanup = TestClass.new
    VARS.each { |ivar_s| cleanup.send("#{ivar_s}_destroy!".to_sym) }
    self.class.class_eval('remove_const(:TestClass)')
  end

  def get_object
    test_obj =TestClass.new
    VARS.each do |ivar_s|
      ivar_sym = ivar_s.to_sym
      if (ivar_s =~ %r!cc$!)
        assert_equal(0, test_obj.send(ivar_sym),
                     "@#{ivar_s} should be 0")
      else
        assert_nil(test_obj.send(ivar_sym),
                   "@#{ivar_s} should be nil")
      end
    end
    return test_obj
  end

  def test_01_test_custom_names
    test_obj = get_object
    VARS.each do |ivar_s|
      ivar_sym = ivar_s.to_sym
      expected = 'test-%s' % [ ivar_s ]
      test_val = test_obj.instance_variable_get("@#{ivar_s}".to_sym).name
      assert_equal(expected, test_val,
                   "@#{ivar_s}'s name should be '#{expected}'")
    end
  end

  def test_02_test_sharedness
    test_obj = get_object
    VARS.each do |ivar_s|
      ivar_sym = ivar_s.to_sym
      test_var = test_obj.instance_variable_get("@#{ivar_s}".to_sym)
      expect_shared = (ivar_s =~ %r!^s!) ? true : false
      assert_equal(expect_shared, test_var.shared?,
                   "@#{ivar_s}.shared? should be #{expect_shared.inspect}")
      assert_not_equal(expect_shared, test_var.private?,
                       "@#{ivar_s}.private? should not be #{expect_shared.inspect}")
    end
  end

  def test_03_test_locking
    main_obj = get_object
    test_obj = get_object
    VARS.each do |ivar_s|
      ivar_sym = ivar_s.to_sym
      main_var = main_obj.instance_variable_get("@#{ivar_s}".to_sym)
      test_var = test_obj.instance_variable_get("@#{ivar_s}".to_sym)
      assert(main_var.lock,
             "main_var:@#{ivar_s}.lock should return true")
      assert(! test_var.lock,
             "test_var:@#{ivar_s}.lock should return false or nil")
      assert(main_var.lock,
             "main_var:@#{ivar_s}.lock should return true")
    end
  end

  def test_04_test_finaliser_unlocking
    main_obj = get_object
    test_obj = get_object
    VARS.each do |ivar_s|
      ivar_sym = ivar_s.to_sym
      main_var = main_obj.instance_variable_get("@#{ivar_s}".to_sym)
      test_var = test_obj.instance_variable_get("@#{ivar_s}".to_sym)
      assert(main_var.lock,
             "main_var:@#{ivar_s}.lock should return true")
      assert(! test_var.lock,
             "test_var:@#{ivar_s}.lock should return false or nil")
      assert(main_var.lock,
             "main_var:@#{ivar_s}.lock should return true")
    end
  end

  def test_06_test_multilocking
    test_obj = get_object
    VARS.each do |ivar_s|
      ivar_sym = ivar_s.to_sym
      main_var = test_obj.instance_variable_get("@#{ivar_s}".to_sym)
      main_var.lock
      threads = []
      100.times do
        alt_obj = get_object
        alt_var = alt_obj.instance_variable_get("@#{ivar_s}".to_sym)
        assert_not_equal(main_var, alt_var,
                         "alt_var.#{ivar_s} should not match main_var's")
        assert_equal(main_var.name, alt_var.name,
                     "alt_var.#{ivar_s}'s name should match main_var's")
        attempt_lock = Proc.new { Thread.current[:locked] = alt_var.lock }
        threads << Thread.new { attempt_lock }
      end
      threads.each do |thred|
        thred.join
        assert(! thred[:locked],
               "#{thred.inspect}[:locked] should be false for @#{ivar_s}")
      end
    end
  end

end
