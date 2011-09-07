require File.dirname(__FILE__) + '/test_helper.rb'
require 'thread'
require 'ruby-debug'
Debugger.start

class TestInstantCacheSimpleSharing < Test::Unit::TestCase

  TestClass_def = <<-'EOT'
    class TestClass
      include InstantCache
      memcached_accessor(:umca)	{ |ivar| "#{TestName.call}-#{ivar.to_s}" }
      memcached_reader(:umcr)	{ |ivar| "#{TestName.call}-#{ivar.to_s}" }
      memcached_counter(:umcc)	{ |ivar| "#{TestName.call}-#{ivar.to_s}" }
      memcached_accessor(InstantCache::PRIVATE, :pmca)
      memcached_reader(InstantCache::PRIVATE, :pmcr)
      memcached_counter(InstantCache::PRIVATE, :pmcc)
      memcached_accessor(InstantCache::SHARED, :smca) \
				{ |ivar| "#{TestName.call}-#{ivar.to_s}" }
      memcached_reader(InstantCache::SHARED, :smcr) \
				{ |ivar| "#{TestName.call}-#{ivar.to_s}" }
      memcached_counter(InstantCache::SHARED, :smcc) \
				{ |ivar| "#{TestName.call}-#{ivar.to_s}" }
    end
  EOT

  VARS = %w( umca umcr umcc pmca pmcr pmcc smca smcr smcc )

  def setup
    unless (self.class.constants.include?('TestName'))
      #
      # Create a closure to make the test class instance available to
      # the custom-name blocks.
      #
      self.class.const_set('TestName',
                           Proc.new {
                             self.class.name +
                             '::' +
                             self.instance_variable_get(:@method_name)
                           })
    end
    #
    # Make the connexion to the memcache cluster.
    #
    if (InstantCache.cache_object.nil?)
      InstantCache.cache_object = MemCache.new('127.0.0.1:11211')
    end
    if (self.class.const_defined?(:TestClass))
      self.class.class_eval('remove_const(:TestClass)')
    end
    self.class.class_eval(TestClass_def)
    @test_objects = []
  end

  def teardown
    @test_objects.each do |o|
      VARS.each do |ivar_s|
        cell = o.instance_variable_get("@#{ivar_s}".to_sym)
        cellname = cell.name
        InstantCache.cache_object.delete(cellname)
        cell.destroy! unless (cell.destroyed?)
      end
    end
    unless (self.class.const_defined?(:TestClass))
      self.class.class_eval(TestClass_def)
    end
    cleanup = TestClass.new
    VARS.each { |ivar_s| cleanup.send("#{ivar_s}_destroy!".to_sym) }
    self.class.class_eval('remove_const(:TestClass)')
  end

  def get_object
    @test_objects << (test_obj = TestClass.new)
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
      #
      # Skip over the private ones for now, since we're not sure of their
      # names.
      #
      next if (ivar_s[0,1] == 'p')
      ivar_sym = ivar_s.to_sym
      expected = '%s-%s' % [ TestName.call, ivar_s ]
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
      expect_shared = (ivar_s =~ %r!^p!) ? false : true
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
      main_lock = main_var.lock
      test_lock = test_var.lock
      assert(main_lock,
             "main_var:@#{ivar_s}.lock should return true")
      if (main_var.shared? && test_var.shared?)
        assert(! test_lock,
               "shared test_var:@#{ivar_s}.lock should return false or nil")
      else
        assert(test_lock,
               "private test_var:@#{ivar_s}.lock should return true")
      end
    end
  end

  def test_04_test_multilocking
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
        if (ivar_s[0,1] == 'p')
          assert_not_equal(main_var.name, alt_var.name,
                           "alt_var.#{ivar_s}'s name should not match main_var's")
        else
          assert_equal(main_var.name, alt_var.name,
                       "alt_var.#{ivar_s}'s name should match main_var's")
        end
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
