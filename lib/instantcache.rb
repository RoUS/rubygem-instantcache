require 'memcache'
#
# Provide accessors that actually store the 'instance variables'
# in memcached.
#
module InstantCache

  class << self

    attr_accessor(:cache_object)

  end

  #
  # We try to make our 'instance variables' act like the real thing,
  # even though they're objects wrapping memcached cells.
  #
  # FIXME: the replacement of instance_variable_xxx isn't correct
  #
  def included(base_klass)
    unless (base_klass.respond_to?(:_memcached_overridden_ivar_get))
      base_klass.__send__(:alias_method,
                          :_memcached_overridden_ivar_get,
                          :instance_variable_get)
      def instance_variable_get(ivar)
        val = self._memcached_overridden_ivar_get(ivar)
        return val unless (val.kind_of?(Blob))
        return val.get
      end

      base_klass.__send__(:alias_method,
                          :_memcached_overridden_ivar_set,
                          :instance_variable_set)
      def instance_variable_set(ivar, ivar_val)
        val = self._memcached_overridden_ivar_get(ivar)
        unless (val.kind_of?(Blob))
          return self._memcached_overridden_ivar_set(ivar, ivar_val)
        end
        return val.set(ivar_val)
      end
    end

  end

  #
  # Class for J Random Arbitrary Data stored in memcache.
  #
  class Blob

    RESET_VALUE = nil
    
    attr_accessor(:expiry)
    attr_reader(:rawmode)
    attr_reader(:locked)
    
    #
    # Not-for-public-consumption methods.
    #
    def lock_name
      return self.name + '-lock'
    end
    protected(:lock_name)
    
    #
    # Constructor of a non-raw object.
    #
    def initialize(inival=nil)
      @rawmode = false
      @expiry = 0
      self.set(inival) unless(inival.nil?)
    end
    
    def reset
      rval = nil
      if (self.class.constants.include?('RESET_VALUE'))
        rval = self.class.const_get('RESET_VALUE')
      end
      InstantCache.cache_object.set(self.name, rval, self.expiry, self.rawmode)
      return rval
    end
    
    #
    # Used to determine the name of the memcache cell.
    #
    def name
      raise RuntimeError.new('#name method must be defined in instance')
    end
    
    #
    # Try to obtain an interlock on the memcached cell.  If successful,
    # returns true -- else, the cell is locked by someone else and
    # we should proceed accordingly.
    #
    # This makes use of the memcached convention that #add is a no-op
    # if the cell already exists; we use that to try to create the
    # interlock cell.
    #
    def lock
      return true if (@locked)
      sts = InstantCache.cache_object.add(self.lock_name, true)
      @locked = (sts.to_s =~ %r!^STORED!) ? true : false
      return @locked
    end
    
    #
    # If we have the cell locked, unlock it by deleting the
    # interlock cell (allowing someone else's #lock(#add) to work).
    #
    def unlock
      return false unless (@locked)
      sts = InstantCache.cache_object.get(self.lock_name)
      if (sts != @locked)
        msg = ('memcache lock status inconsistency for %s: ' +
               'memcache=%s, @locked=%s')
        msg = msg % [ self.name, sts.inspect, @locked.inspect ]
        raise RuntimeError.new(msg)
      end
      @locked = false
      sts = InstantCache.cache_object.delete(self.lock_name)
      if (sts !~ %r!^DELETED!)
        msg = ('memcache lock status inconsistency for %s: ' +
               'memcache=%s, expected="DELETED"')
        msg = msg % [ self.name, sts.to_s.chomp.inspect ]
        raise RuntimeError.new(msg)
      end
      return true
    end
    
    #
    # Fetch the value out of memcached.
    #
    def get
      return InstantCache.cache_object.get(self.name, self.rawmode)
    end
    alias_method(:read, :get)
    
    #
    # Write a value into memcached.
    #
    def set(val)
      InstantCache.cache_object.add(self.name, val, self.expiry, self.rawmode)
      InstantCache.cache_object.set(self.name, val, self.expiry, self.rawmode)
      return self.get
    end
    alias_method(:write, :set)
    
    #
    # Just return the string representaton of the value, not
    # this instance.
    #
    def to_s(*args)
      return self.get.__send__(:to_s, *args)
    end
    
  end                           # End of class Blob
  
  #
  # Class for integer-only memcache cells, capable of atomic
  # increment/decrement.  Basically the same as Blob, except
  # with rawmode forced to true.
  #
  class Counter < Blob
    
    RESET_VALUE = 0
    
    def initialize(inival=nil)
      @rawmode = true
      @expiry = 0
      self.set(inival) unless (inival.nil?)
    end
    
    #
    # Get the value through the superclass, and convert to integer.
    # (Raw values get stored as strings, since they're unmarshalled.)
    #
    def get
      return super.to_i
    end
    
    #
    # Store a value as an integer, and return it.
    #
    def set(val)
      return super(val.to_i).to_i
    end
    
    #
    # Increment a memcached raw cell.  This *only* works in raw mode,
    # but it's atomic.
    #
    def increment(amt=1)
      return InstantCache.cache_object.incr(self.name, amt)
    end
    alias_method(:incr, :increment)
    
    #
    # As for #increment.
    #
    def decrement(amt=1)
      return InstantCache.cache_object.decr(self.name, amt)
    end
    alias_method(:decr, :decrement)
    
  end                           # End of class Counter < Blob
  
  class << self
    
    Setup =<<-'EOT'
      def _initialise_%s
        if (@%s.nil?)
          mvar = Clonepin::MemcachedVar::%s.new
          cellname = self.class.name
          cellname << ':0x' << ((self.object_id << 1) & 0xffffffff).to_s(16)
          cellname << ':@%s'
          mvar.instance_eval(%%Q{
            def name
              return '#{cellname}'
            end})
          mvar.reset
          @%s = mvar
          return true
        end
        return false
      end
      private(:_initialise_%s)
      def %s_lock
        self.__send__(:_initialise_%s)
        return @%s.lock
      end
      def %s_unlock
        self.__send__(:_initialise_%s)
        return @%s.unlock
      end
    EOT

    Reader =<<-'EOT'
      def %s
        self.__send__(:_initialise_%s)
        return @%s.get
      end
    EOT

    Writer =<<-'EOT'
      def %s=(newval)
        self.__send__(:_initialise_%s)
        return @%s.set(newval)
      end
    EOT

    Counter =<<-'EOT'
      def %s_increment(amt=1)
        self.__send__(:_initialise_%s)
        return @%s.increment(amt)
      end
      alias_method(:%s_incr, :%s_increment)
      def %s_decrement(amt=1)
        self.__send__(:_initialise_%s)
        return @%s.decrement(amt)
      end
      alias_method(:%s_decr, :%s_decrement)
    EOT

    EigenReader = Proc.new { |*args|
      args.each do |ivar|
        subslist = [ ivar.to_s ] * 11
        subslist.insert(2, 'Blob')
        class_eval(Setup % subslist)
        subslist.delete_at(2)
        class_eval(Reader % subslist)
      end
      nil
    }                           # End of Proc EigenReader

    EigenAccessor = Proc.new { |*args|
      args.each do |ivar|
        subslist = [ ivar.to_s ] * 11
        subslist.insert(2, 'Blob')
        class_eval(Setup % subslist)
        subslist.delete_at(2)
        class_eval(Reader % subslist)
        class_eval(Writer % subslist)
      end
      nil
    }                           # End of Proc EigenAccessor

    EigenCounter = Proc.new { |*args|
      args.each do |ivar|
        subslist = [ ivar.to_s ] * 22
        subslist.insert(2, 'Counter')
        class_eval(Setup % subslist)
        subslist.delete_at(2)
        class_eval(Reader % subslist)
        class_eval(Writer % subslist)
        class_eval(Counter % subslist)
      end
      nil
    }                           # End of Proc EigenCounter

    def included(base_klass)
      base_eigenklass = base_klass.class_eval('class << self ; self ; end')
      base_eigenklass.__send__(:define_method,
                               :memcached_reader,
                               EigenReader)
      base_eigenklass.__send__(:define_method,
                               :memcached_accessor,
                               EigenAccessor)
      base_eigenklass.__send__(:define_method,
                               :memcached_counter,
                               EigenCounter)
      return nil
    end                         # End of def included
    
  end                           # End of module InstantCache eigenclass

  #
  # This should be overridden by inheritors; it's used to form the name
  # of the memcached cell.
  #
  def name
    return "Unnamed-#{self.class.name}-object"
  end                           # End of def name

end                             # End of module InstantCache
