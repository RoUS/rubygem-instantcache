# -*- coding: utf-8 -*-
#
# = instantcache.rb - InstantCache module
#
# Author::      Ken Coar
# Copyright::   Copyright © 2011 Ken Coar
# License::     Apache Licence 2.0
#
# == Synopsis
#
#    require 'rubygems'
#    require 'memcache'
#    require 'instantcache'
#    InstantCache.cache_object = MemCache.new('127.0.0.1:11211')
#
#    class Foo
#      include InstantCache
#      memcached_accessor(:bar)
#    end
#
#    f = Foo.new
#    f.bar
#    => nil
#    f.bar = f
#    => #<Foo:0xb7438c64 @bar=#<InstantCache::Blob:0xc74f882>>
#    f.bar = %w( one two three )
#    => ["one","two","three"]
#    f.bar << :four
#    => ["one","two","three",:four]
#    f.bar[1,1]
#    => "two"
#    f.bar_destroy!
#    => nil
#    f.bar
#    InstantCache::Destroyed: attempt to access destroyed variable
#
# == Description
#
# InstantCache provides accessor declarations, and the necessary
# underpinnings, to allow you to share instance variables across a
# memcached cluster.
#
#--
#   Copyright © 2011 Ken Coar
#
#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at
#
#       http://www.apache.org/licenses/LICENSE-2.0
#
#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License.
#++

require 'delegate'
require 'thread'
require 'memcache'
require 'versionomy'
require 'instantcache/exceptions'

require 'ruby-debug'
Debugger.start

#
# Provide accessors that actually store the 'instance variables'
# in memcached.
#
module InstantCache

  Version = Versionomy.parse('0.1.0a1')
  VERSION = Version.to_s.freeze

  #
  # Label informing accessor declarations that the variable is to be
  # shared.  This changes how some things are done (like default
  # memcached cell names).
  #
  SHARED	= :SHARED
  #
  # Marks a variable as deliberately private and unshared.  It can
  # still be accessed through memcached calls if you know how, but it
  # isn't made easy -- it's supposed to be private, after all.
  #
  PRIVATE	= :PRIVATE

  class << self

    #
    # The memcached instance is currently a class-wide value.
    #
    attr_accessor(:cache_object)

    #
    # === Description
    # :call-seq:
    # === Arguments
    # === Exceptions
    # [<tt>InstantCache::Destroyed</tt>]
    #
    def enwrap(target)
      #
      # Shamelessly cadged from delegator.rb
      #
      eigenklass = eval('class << target ; self ; end')
      preserved = ::Kernel.public_instance_methods(false)
      preserved -= [ 'to_s', 'to_a', 'inspect', '==', '=~', '===' ]
      swbd = {}
      target.instance_variable_set(:@_instantcache_method_map, swbd)
      target.instance_variable_set(:@_instantcache_datatype, target.class)
      for t in self.class.ancestors
        preserved |= t.public_instance_methods(false)
        preserved |= t.private_instance_methods(false)
        preserved |= t.protected_instance_methods(false)
      end
      preserved << 'singleton_method_added'
      target.methods.each do |method|
        next if (preserved.include?(method))
        swbd[method] = target.method(method.to_sym)
        target.instance_eval(<<-EOS)
          def #{method}(*args, &block)
            iniself = self.clone
            result = @_instantcache_method_map['#{method}'].call(*args, &block)
            if (self != iniself)
              #
              # Store the changed entity
              #
              newklass = self.class
              iniklass = iniself.instance_variable_get(:@_instantcache_datatype)
              unless (self.kind_of?(iniklass))
                begin
                  raise InstantCache::IncompatibleType.new(newklass.name,
                                                           iniklass.name,
                                                           'TBS')
                rescue InstantCache::IncompatibleType
                  if ($@)
                    $@.delete_if { |s|
                      %r"\A#{Regexp.quote(__FILE__)}:\d+:in `" =~ s
                    }
                  end
                  raise
                end
              end
              owner = self.instance_variable_get(:@_instantcache_owner)
              owner.set(self)
            end
            return result
          end
        EOS
      end
    end                         # End of def enwrap

  end                           # End of module InstantCache eigenclass

  #
  # Class for J Random Arbitrary Data stored in memcache.
  #
  class Blob

    RESET_VALUE = nil

    attr_accessor(:expiry)
    attr_reader(:rawmode)
    attr_reader(:locked_by_us)
    attr_reader(:identity)

    #
    # Constructor of a non-raw object.
    #
    #
    # === Description
    # :call-seq:
    # === Arguments
    # === Exceptions
    # [<tt>InstantCache::Destroyed</tt>]
    #
    def initialize(inival=nil)
      @rawmode ||= false
      @expiry = 0
      @locked_by_us = false
      idfmt = 'host[%s]:pid[%d]:thread[%d]:%s[%d]'
      idargs = []
      idargs << `hostname`.chomp.strip
      idargs << $$
      idargs << Thread.current.object_id
      idargs << self.class.name.sub(%r!^.*::!, '')
      idargs << self.object_id
      @identity = idfmt % idargs
      self.set(inival) unless(inival.nil?)
    end

    #
    # === Description
    # :call-seq:
    # === Arguments
    # === Exceptions
    # [<tt>InstantCache::Destroyed</tt>]
    #
    def reset
      raise Destroyed.new(self.name) if (self.destroyed?)
      rval = nil
      if (self.class.constants.include?('RESET_VALUE'))
        rval = self.class.const_get('RESET_VALUE')
      end
      #
      # TODO: This interferes with subclassing; better way to locate the cache
      #
      InstantCache.cache_object.set(self.name, rval, self.expiry, self.rawmode)
      return rval
    end

    #
    # Used to determine the name of the memcache cell.
    #
    #
    # === Description
    # :call-seq:
    # === Arguments
    # === Exceptions
    # [<tt>InstantCache::Destroyed</tt>]
    #
    def name
      raise RuntimeError.new('#name method must be defined in instance')
    end

    #
    # === Description
    # :call-seq:
    # === Arguments
    # === Exceptions
    # [<tt>InstantCache::Destroyed</tt>]
    #
    def destroyed?
      return false
    end

    #
    # === Description
    # :call-seq:
    # === Arguments
    # === Exceptions
    # [<tt>InstantCache::Destroyed</tt>]
    #
    def destroy!
      raise Destroyed.new(self.name) if (self.destroyed?)
      self.unlock
      self.instance_eval('def destroyed? ; return true ; end')
      return nil
    end

    #
    # Not-for-public-consumption methods.
    #
    #
    # === Description
    # :call-seq:
    # === Arguments
    # === Exceptions
    # [<tt>InstantCache::Destroyed</tt>]
    #
    def lock_name
      return self.name + '-lock'
    end
    protected(:lock_name)

    #
    # Try to obtain an interlock on the memcached cell.  If successful,
    # returns true -- else, the cell is locked by someone else and
    # we should proceed accordingly.
    #
    # This makes use of the memcached convention that #add is a no-op
    # if the cell already exists; we use that to try to create the
    # interlock cell.
    #
    #
    # === Description
    # :call-seq:
    # === Arguments
    # === Exceptions
    # [<tt>InstantCache::Destroyed</tt>]
    #
    def lock
      raise Destroyed.new(self.name) if (self.destroyed?)
      return true if (@locked_by_us)
      sts = InstantCache.cache_object.add(self.lock_name, @identity)
      @locked_by_us = (sts.to_s =~ %r!^STORED!) ? true : false
      return @locked_by_us
    end

    #
    # If we have the cell locked, unlock it by deleting the
    # interlock cell (allowing someone else's #lock(#add) to work).
    #
    #
    # === Description
    # :call-seq:
    # === Arguments
    # === Exceptions
    # [<tt>InstantCache::Destroyed</tt>]
    #
    def unlock
      raise Destroyed.new(self.name) if (self.destroyed?)
      sts = InstantCache.cache_object.get(self.lock_name) || false
      if (@locked_by_us && (sts != @identity))
        #
        # If we show we have the lock, but the lock cell doesn't exist
        # (or isn't us), that's definitely an inconsistency.
        #
        e = LockInconsistency.new(self.lock_name,
                                  @identity,
                                  sts.inspect)
        raise e
      end
      return false unless (@locked_by_us)
      @locked_by_us = false
      sts = InstantCache.cache_object.delete(self.lock_name)
      if (sts !~ %r!^DELETED!)
        e = LockInconsistency.new(self.lock_name,
                                  '/DELETED/',
                                  sts.inspect)
        raise e
      end
      return true
    end

    #
    # Fetch the value out of memcached.
    #
    #
    # === Description
    # :call-seq:
    # === Arguments
    # === Exceptions
    # [<tt>InstantCache::Destroyed</tt>]
    #
    def get
      raise Destroyed.new(self.name) if (self.destroyed?)
      value = InstantCache.cache_object.get(self.name, self.rawmode)
      begin
        value.clone
        value.instance_variable_set(:@_instantcache_owner, self)
        InstantCache.enwrap(value)
      rescue
        #
        # If the value was something we couldn't clone, like a Fixnum,
        # it's inherently immutable.  That's our position ayup.
        #
      end
      return value
    end
    alias_method(:read, :get)

    #
    # Write a value into memcached.
    #
    #
    # === Description
    # :call-seq:
    # === Arguments
    # === Exceptions
    # [<tt>InstantCache::Destroyed</tt>]
    #
    def set(val_p)
      raise Destroyed.new(self.name) if (self.destroyed?)
      begin
        val = val_p.clone
      rescue TypeError => e
        val = val_p
      end
      remap = val.instance_variable_get(:@_instantcache_method_map)
      if (remap.kind_of?(Hash))
        remap.keys.each do |method|
          begin
            eval("class << val ; remove_method(:#{method}) ; end")
          rescue
          end
        end
        val.instance_variable_set(:@_instantcache_method_map, nil)
        val.instance_variable_set(:@_instantcache_owner, nil)
      end
      InstantCache.cache_object.add(self.name, val, self.expiry, self.rawmode)
      InstantCache.cache_object.set(self.name, val, self.expiry, self.rawmode)
      return self.get
    end
    alias_method(:write, :set)

    #
    # Just return the string representaton of the value, not
    # this instance.
    #
    #
    # === Description
    # :call-seq:
    # === Arguments
    # === Exceptions
    # [<tt>InstantCache::Destroyed</tt>]
    #
    def to_s(*args)
      raise Destroyed.new(self.name) if (self.destroyed?)
      return self.get.__send__(:to_s, *args)
    end

    #
    # === Description
    # :call-seq:
    # === Arguments
    # === Exceptions
    # [<tt>InstantCache::Destroyed</tt>]
    #
    def method_missing(meth, *args)
      methsym = meth.to_sym
      return self.__send__(methsym, *args) if (self.respond_to?(methsym))
      curval = self.get
      lastval = curval.clone
      opresult = curval.__send__(methsym, *args)
      if (curval != lastval)
        self.set(curval)
      end
      return opresult
    end

  end                           # End of class Blob

  #
  # Class for integer-only memcache cells, capable of atomic
  # increment/decrement.  Basically the same as Blob, except
  # with rawmode forced to true.
  #
  class Counter < Blob

    RESET_VALUE = 0

    #
    # === Description
    # :call-seq:
    # === Arguments
    # === Exceptions
    # [<tt>InstantCache::Destroyed</tt>]
    #
    def initialize(inival=nil)
      @rawmode = true
      super
    end

    #
    # Get the value through the superclass, and convert to integer.
    # (Raw values get stored as strings, since they're unmarshalled.)
    #
    #
    # === Description
    # :call-seq:
    # === Arguments
    # === Exceptions
    # [<tt>InstantCache::Destroyed</tt>]
    #
    def get
      return super.to_i
    end

    #
    # Store a value as an integer, and return it.
    #
    #
    # === Description
    # :call-seq:
    # === Arguments
    # === Exceptions
    # [<tt>InstantCache::Destroyed</tt>]
    #
    def set(val)
      unless (val.kind_of?(Integer))
        raise CounterIntegerOnly.new(self.ivar_name.inspect)
      end
      return super(val.to_i).to_i
    end

    #
    # Increment a memcached raw cell.  This *only* works in raw mode,
    # but it's atomic.
    #
    #
    # === Description
    # :call-seq:
    # === Arguments
    # === Exceptions
    # [<tt>InstantCache::Destroyed</tt>]
    #
    def increment(amt=1)
      raise Destroyed.new(self.name) if (self.destroyed?)
      return InstantCache.cache_object.incr(self.name, amt)
    end
    alias_method(:incr, :increment)

    #
    # As for #increment.
    #
    #
    # === Description
    # :call-seq:
    # === Arguments
    # === Exceptions
    # [<tt>InstantCache::Destroyed</tt>]
    #
    def decrement(amt=1)
      raise Destroyed.new(self.name) if (self.destroyed?)
      return InstantCache.cache_object.decr(self.name, amt)
    end
    alias_method(:decr, :decrement)

  end                           # End of class Counter < Blob

  class << self

    Setup =<<-'EOT'
      def _initialise_%s
        unless (self.instance_variables.include?('@%s') \
                && @%s.kind_of?(InstantCache::Blob))
          mvar = InstantCache::%s.new
          cellname = self.class.name + ':'
          cellname << self.object_id.to_s
          cellname << ':@%s'
          shared = %s
          owner = ObjectSpace._id2ref(self.object_id)
          mvar.instance_eval(%%Q{
            def name
              return '%s'
            end
            def shared?
              return #{shared.inspect}
            end
            def private?
              return (! self.shared?)
            end
            def owner
              return ObjectSpace._id2ref(#{self.object_id})
            end})
          @%s = mvar
          ObjectSpace.define_finalizer(owner, Proc.new { mvar.unlock })
          unless (shared)
            mvar.reset
            finaliser = Proc.new {
              InstantCache.cache_object.delete(mvar.name)
              InstantCache.cache_object.delete(mvar.send(:lock_name))
            }
            ObjectSpace.define_finalizer(owner, finaliser)
          end
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
      def %s_expiry
        self.__send__(:_initialise_%s)
        return @%s.__send__(:expiry)
      end
      def %s_expiry=(val=0)
        self.__send__(:_initialise_%s)
        return @%s.__send__(:expiry=, val)
      end
      def %s_reset
        self.__send__(:_initialise_%s)
        return @%s.__send__(:reset)
      end
      def %s_destroy!
        self.__send__(:_initialise_%s)
        return @%s.__send__(:destroy!)
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

    EigenReader = Proc.new { |*args,&block|
      shared = true
      if ([ :SHARED, :PRIVATE ].include?(args[0]))
        shared = (args.shift == :SHARED)
      end
      args.each do |ivar|
        ivar_s = ivar.to_s
        if (block)
          if (shared)
            name = block.call(ivar)
          else
            raise SharedOnly.new(ivar.to_sym.inspect)
          end
        end
        name ||= '#{cellname}'
        subslist = (([ ivar_s ] * 3) +
                    [ 'Blob', ivar_s, shared.inspect, name] +
                    ([ ivar_s ] * 20))
        class_eval(Setup % subslist)
        class_eval(Reader % subslist[0, 3])
      end
      nil
    }                           # End of Proc EigenReader

    EigenAccessor = Proc.new { |*args,&block|
      shared = true
      if ([ :SHARED, :PRIVATE ].include?(args[0]))
        shared = (args.shift == :SHARED)
      end
      args.each do |ivar|
        ivar_s = ivar.to_s
        if (block)
          if (shared)
            name = block.call(ivar)
          else
            raise SharedOnly.new(ivar.to_sym.inspect)
          end
        end
        name ||= '#{cellname}'
        subslist = (([ ivar_s ] * 3) +
                    [ 'Blob', ivar_s, shared.inspect, name] +
                    ([ ivar_s ] * 20))
        class_eval(Setup % subslist)
        class_eval(Reader % subslist[0, 3])
        class_eval(Writer % subslist[0, 3])
      end
      nil
    }                           # End of Proc EigenAccessor

    EigenCounter = Proc.new { |*args,&block|
      shared = true
      if ([ :SHARED, :PRIVATE ].include?(args[0]))
        shared = (args.shift == :SHARED)
      end
      args.each do |ivar|
        ivar_s = ivar.to_s
        if (block)
          if (shared)
            name = block.call(ivar)
          else
            raise SharedOnly.new(ivar.to_sym.inspect)
          end
        end
        name ||= '#{cellname}'
        subslist = (([ ivar_s ] * 3) +
                    [ 'Counter', ivar_s, shared.inspect, name] +
                    ([ ivar_s ] * 20))
        class_eval(Setup % subslist)
        subslist.delete_at(6)
        subslist.delete_at(5)
        subslist.delete_at(3)
        class_eval(Reader % subslist[0, 3])
        class_eval(Writer % subslist[0, 3])
        class_eval(Counter % subslist[0, 10])
      end
      nil
    }                           # End of Proc EigenCounter

    #
    # === Description
    # :call-seq:
    # === Arguments
    # === Exceptions
    # [<tt>InstantCache::Destroyed</tt>]
    #
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
    #
    # === Description
    # :call-seq:
    # === Arguments
    # === Exceptions
    # [<tt>InstantCache::Destroyed</tt>]
    #
  def name
    return "Unnamed-#{self.class.name}-object"
  end                           # End of def name

end                             # End of module InstantCache
