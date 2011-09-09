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

  #
  # The base Versionomy representation of the package version.
  #
  Version = Versionomy.parse('0.1.1')

  #
  # The package version-as-a-string.
  #
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
    # Wrapper for the @cache_object class variable.
    #
    # :call-seq:
    # InstantCache.cache.<i>method</i>
    #
    # === Arguments
    # <i>None.</i>
    #
    # === Exceptions
    # [<tt>InstantCache::NoCache</tt>] Cache object unset or misset.
    #
    def cache                   # :nodoc
      mco = (InstantCache.cache_object ||= nil)
      return mco if (mco.kind_of?(MemCache))
      raise NoCache
    end

    #
    # === Description
    # Add singleton wrapper methods to a copy of the cached value.
    #
    # :call-seq:
    # InstantCache.enwrap(<i>cacheval</i>) => nil
    #
    # === Arguments
    # [<i>cacheval</i>] Variable containing value fetched from memcache.
    #
    # === Exceptions
    # [<tt>InstantCache::Destroyed</tt>] Cache value instance has been
    #                                    destroyed and is no longer usable.
    #                                    The value in the cache is unaffected.
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
      return nil
    end                         # End of def enwrap

    #
    # === Description
    # Removes any singleton methods added by the #enwrap class method.
    # If the argument doesn't have any (<i>e.g.</i>, isn't a value that
    # was previously fetched), this is a no-op.
    #
    # :call-seq:
    # InstantCache.unwrap(<i>target</i>) => nil
    #
    # === Arguments
    # [<i>target</i>] Variable containing value previously fetched
    #                 from memcache.
    #
    # === Exceptions
    # <i>None.</i>
    #
    def unwrap(target)
      remap = target.instance_variable_get(:@_instantcache_method_map)
      return nil unless (remap.kind_of?(Hash))
      remap.keys.each do |method|
        begin
          eval("class << target ; remove_method(:#{method}) ; end")
        rescue
        end
      end
      target.instance_variable_set(:@_instantcache_method_map, nil)
      target.instance_variable_set(:@_instantcache_owner, nil)
      return nil
    end                        # End of def unwrap

  end                          # End of module InstantCache eigenclass

  #
  # The 'Blob' class is used to store data of arbitrary and opaque
  # format in the cache.  This is used for just about all cases except
  # integer counters, which have their own class.
  #
  class Blob

    class << self
      #
      # === Description
      # Access method declarator for a read/write memcache-backed
      # variable.
      #
      # This declarator sets up several methods relating to the
      # variable.  If the name passed is <b><tt>:ivar</tt></b>, these
      # methods are created for it:
      #
      # [<i>ivar</i>]            Normal read accessor
      #                          (<i>e.g.</i>, <tt>obj.ivar</tt>).
      #                          (See Blob#set)
      # [<i>ivar</i>=]           Normal write accessor
      #                          (<i>e.g.</i>, <tt>obj.ivar = 17</tt>).
      #                          (See Blob#get)
      # [<i>ivar</i>_reset]      Resets the cache variable to the default
      #                          'uninitialised' value.
      #                          (See Blob#reset)
      # [<i>ivar</i>_expiry]     Returns the current cache lifetime
      #                          (default 0).
      #                          (See Blob#expiry)
      # [<i>ivar</i>_expiry=]    Sets the cache lifetime.
      #                          (See Blob#expiry=)
      # [<i>ivar</i>_lock]       Tries to get an exclusive lock on the
      #                          variable.
      #                          (See Blob#lock)
      # [<i>ivar</i>_unlock]     Unlocks the variable if locked.
      #                          (See Blob#unlock)
      # [<i>ivar</i>_destroyed?] Returns true if variable is disconnected
      #                          from the cache and unusable.
      #                          (See Blob#destroyed?)
      # [<i>ivar</i>_destroy!]   Disconnects the variable from the cache
      #                          and makes it unusable.
      #                          (See Blob#destroy!)
      #
      # :call-seq:
      # memcached_accessor(<i>symbol</i>[,...])
      # memcached_accessor(<i>symbol</i>[,...]) { |symbol| ... }
      #
      # === Arguments
      # [<i>symbol</i>] As with other Ruby accessor declarations, the argument
      #                 list consists of one or more variable names represented
      #                 as symbols (<i>e.g.</i>, <tt>:variablename</tt>).
      # [<i>{block}</i>] If a block is supplied, its return value must
      #                  be a string, which will be used as the name of
      #                  the memcached cell backing the variable.  The
      #                  argument to the block is the name of the
      #                  variable as passed to the accessor declaration.
      #
      # === Exceptions
      # <i>None.</i>
      #
      #--
      # This will be overridden later, but we need to declare
      # *something* for the rdoc generation to work.
      #++
      def memcached_accessor(*args, &block) ; end

      #
      # === Description
      # Access method declarator for a read-only memcache-backed variable.
      #
      # This declarator sets up several methods relating to the
      # variable.  If the name passed is <b><tt>:ivar</tt></b>, these
      # methods are created for it:
      #
      # [<i>ivar</i>]            Normal read accessor
      #                          (<i>e.g.</i>, <tt>obj.ivar</tt>).
      #                          (See Blob#get)
      # [<i>ivar</i>_reset]      Resets the cache variable to the default
      #                          'uninitialised' value.
      #                          (See Blob#reset)
      # [<i>ivar</i>_expiry]     Returns the current cache lifetime
      #                          (default 0).
      #                          (See Blob#expiry)
      # [<i>ivar</i>_expiry=]    Sets the cache lifetime.
      #                          (See Blob#expiry=)
      # [<i>ivar</i>_lock]       Tries to get an exclusive lock on the
      #                          variable.
      #                          (See Blob#lock)
      # [<i>ivar</i>_unlock]     Unlocks the variable if locked.
      #                          (See Blob#unlock)
      # [<i>ivar</i>_destroyed?] Returns true if variable is disconnected
      #                          from the cache and unusable.
      #                          (See Blob#destroyed?)
      # [<i>ivar</i>_destroy!]   Disconnects the variable from the cache
      #                          and makes it unusable.
      #                          (See Blob#destroy!)
      #
      # :call-seq:
      # memcached_reader(<i>symbol</i>[,...])
      # memcached_reader(<i>symbol</i>[,...]) { |symbol| ... }
      #
      # === Arguments
      # [<i>symbol</i>] As with other Ruby accessor declarations, the argument
      #                 list consists of one or more variable names represented
      #                 as symbols (<i>e.g.</i>, <tt>:variablename</tt>).
      # [<i>{block}</i>] If a block is supplied, its return value must
      #                  be a string, which will be used as the name of
      #                  the memcached cell backing the variable.  The
      #                  argument to the block is the name of the
      #                  variable as passed to the accessor declaration.
      #
      # === Exceptions
      # <i>None.</i>
      #
      #--
      # This will be overridden later, but we need to declare
      # *something* for the rdoc generation to work.
      #++
      def memcached_reader(*args, &block) ; end

    end                         # End of class Blob eigenclass

    #
    # When a cached value of this type is reset or cleared,
    # exactly what value is used to do so?  This is overridden in
    # subclasses as needed.
    #
    RESET_VALUE = nil

    #
    # Memcache expiration (lifetime) for this entity.  Defaults to zero.
    #
    attr_accessor(:expiry)

    #
    # @rawmode is used to signal whether the object is a counter or
    # not.  Counters require memcache raw mode in order for
    # increment/decrement to work; non-raw values are marshalled
    # before storage and hence not atomically accessible in a short
    # instruction stream.
    #
    attr_reader(:rawmode)

    #
    # When we lock a cell in the shared cache, we do so by creating
    # another cell with a related name, in which we store info about
    # ourself so that problems can be traced back to the correct
    # thread/process/system.  That identity is stored here.
    #
    attr_reader(:identity)

    #
    # When we lock a memcached cell, not only do we hang our identity
    # on a interlock cell, but we record the fact locally.
    #
    attr_reader(:locked_by_us)

    #
    # === Description
    # Constructor for a normal (<i>i.e.</i>, non-counter) variable
    # stored in the cache.  This is not intended to be invoked
    # directly except by Those Who Know What They're Doing; rather,
    # cached variables should be declared with the accessor methods
    # <tt>Blob#memcached_accessor</tt> (for read/write access) and
    # <tt>Blob#memcached_reader</tt> (for read-only).
    #
    # :call-seq:
    # new(<i>[val]</i>)
    #
    # === Arguments
    # [<i>val</i>] Value to be loaded into the cache cell.
    #              <b>N.B.:</b> If the cell in question is shared, this
    #              <b>will</b> overwrite the current value if any!
    #
    # === Exceptions
    # <i>None.</i>
    #
    def initialize(inival=nil)
      #
      # This method is defined in the Blob class, for which raw mode
      # is a no-no.  However, to allow simple subclassing, we only set
      # @rawmode if a potential subclass' #initialize hasn't done so.
      # Thus subclasses can get most of the setup work done with a
      # simple invocation of #super.
      #
      @rawmode ||= false
      @expiry = 0
      @locked_by_us = false
      #
      # Fill in our identity for purposes of lock ownership.
      #
      @identity = self.create_identity
      #
      # If we were given an initial value, go ahead and store it.
      # <b>N.B.:</b> If the cell in question is shared, this
      # <b>will</b> overwrite the current value if any!
      #
      self.set(inival) unless(inival.nil?)
    end

    #
    # === Description
    # Create a string that should uniquely identify this instance and
    # a way to locate it.  This is stored in the interlock cell when
    # we obtain exclusive access to the main cached cell, so that we
    # can be tracked down in case of hangs or other problems.
    #
    # This method can be overridden at need.
    #
    # === Arguments
    # <i>None.</i>
    #
    # === Exceptions
    # [<tt>InstantCache::Destroyed</tt>] Cache value instance has been
    #                                    destroyed and is no longer usable.
    #                                    The value in the cache is unaffected.
    #
    def create_identity
      raise Destroyed.new(self.name) if (self.destroyed?)
      idfmt = 'host[%s]:pid[%d]:thread[%d]:%s[%d]'
      idargs = []
      idargs << `hostname`.chomp.strip
      idargs << $$
      idargs << Thread.current.object_id
      idargs << self.class.name.sub(%r!^.*::!, '')
      idargs << self.object_id
      return idfmt % idargs
    end

    #
    # === Description
    # Reset the cache value to its default (typically zero or nil).
    #
    # :call-seq:
    # reset => <i>default reset value</i>
    #
    # === Arguments
    # <i>None.</i>
    #
    # === Exceptions
    # [<tt>InstantCache::Destroyed</tt>] Cache value instance has been
    #                                    destroyed and is no longer usable.
    #                                    The value in the cache is unaffected.
    #
    def reset
      raise Destroyed.new(self.name) if (self.destroyed?)
      rval = nil
      if (self.class.constants.include?('RESET_VALUE'))
        rval = self.class.const_get('RESET_VALUE')
      end
      #
      # TODO: This can mess with subclassing; need better way to find the cache
      #
      InstantCache.cache.set(self.name, rval, self.expiry, self.rawmode)
      return rval
    end

    #
    # === Description
    # The name of the variable declared with #memcached_accessor and
    # friends does <i>not</i> necessarily equate to the name of the
    # cell in the cache.  This method is responsible for creating the
    # latter; the name it returns is also used to identify the
    # interlock cell.
    #
    # This method <b>must</b> be overridden by subclassing; there is
    # no default name syntax for the memcache cells.  (This is done
    # automatically by the <tt>memcached_<i>xxx</i></tt> accessor
    # declarations.)
    #
    # === Arguments
    # <i>None.</i>
    #
    # === Exceptions
    # [<tt>RuntimeError</tt>] This method has not been overridden as required.
    #
    def name
      raise RuntimeError.new('#name method must be defined in instance')
    end

    #
    # === Description
    # Returns true or false according to whether this variable
    # instance has been irrevocably disconnected from any value in the
    # cache.
    #
    # When the instance is destroyed, this method is redefined to
    # return <i>true</i>.
    #
    # === Arguments
    # <i>None.</i>
    #
    # === Exceptions
    # <i>None.</i>
    #
    def destroyed?
      return false
    end

    #
    # === Description
    # Marks this instance as <b>destroyed</b> -- that is to say, any
    # connexion it has to any cached value is severed.  Any
    # outstanding lock on the cache entry is released.  This instance
    # will no longer be usable.
    #
    # === Arguments
    # <i>None.</i>
    #
    # === Exceptions
    # [<tt>InstantCache::Destroyed</tt>] Cache value instance has been
    #                                    destroyed and is no longer usable.
    #                                    The value in the cache is unaffected.
    #
    def destroy!
      raise Destroyed.new(self.name) if (self.destroyed?)
      self.unlock
      self.instance_eval('def destroyed? ; return true ; end')
      return nil
    end

    #:stopdoc:
    # Not-for-public-consumption methods.

    #
    # === Description
    # Create the name of the cached interlock cell based upon the name
    # of the main value cell.
    #
    # === Arguments
    # <i>None.</i>
    #
    # === Exceptions
    # <i>None.</i>
    #
    def lock_name               # :nodoc:
      return self.name + '-lock'
    end
    protected(:lock_name)
    #:startdoc:

    #
    # === Description
    # Try to obtain an interlock on the memcached cell.  If successful,
    # returns true -- else, the cell is locked by someone else and
    # we should proceed accordingly.
    #
    # <b>N.B.:</b> This makes use of the memcached convention that #add
    # is a no-op if the cell already exists; we use that to try to
    # create the interlock cell.
    #
    # The return value is wither <b><tt>true</tt></b> if we obtained
    # (or already held) an exclusive lock, or <b><tt>false</tt></b> if
    # we failed and/or someone else has it locked exclusively.
    #
    # :call-seq:
    # lock => <i>Boolean</i>
    #
    # === Arguments
    # <i>None.</i>
    #
    # === Exceptions
    # [<tt>InstantCache::Destroyed</tt>] Cache value instance has been
    #                                    destroyed and is no longer usable.
    #                                    The value in the cache is unaffected.
    #
    def lock
      raise Destroyed.new(self.name) if (self.destroyed?)
      return true if (@locked_by_us)
      #
      # TODO: Another instance of poor-man's-cache-location; see #reset
      #
      sts = InstantCache.cache.add(self.lock_name, @identity)
      @locked_by_us = (sts.to_s =~ %r!^STORED!) ? true : false
      return @locked_by_us
    end

    #
    # === Description
    # If we have the cell locked, unlock it by deleting the
    # interlock cell (allowing someone else's #lock(#add) to work).
    #
    # This method returns <tt>true</tt> if we held the lock and have
    # released it, or false if we didn't own the lock or the cell
    # isn't locked at all.
    #
    # :call-seq:
    # unlock => <i>Boolean</i>
    #
    # === Arguments
    # <i>None.</i>
    #
    # === Exceptions
    # [<tt>InstantCache::Destroyed</tt>] Cache value instance has been
    #                                    destroyed and is no longer usable.
    #                                    The value in the cache is unaffected.
    # [<tt>InstantCache::LockInconsistency</tt>] The state of the lock
    #                                            on the cell as stored
    #                                            in memcache differs
    #                                            from our local
    #                                            understanding of
    #                                            things.
    #                                            Specifically, we show
    #                                            it as locked by us,
    #                                            but the cache
    #                                            disagrees.
    #
    def unlock
      raise Destroyed.new(self.name) if (self.destroyed?)
      #
      # TODO: Another instance of poor-man's-cache-location; see #reset
      #
      sts = InstantCache.cache.get(self.lock_name) || false
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
      #
      # TODO: Another instance of poor-man's-cache-location; see #reset
      #
      sts = InstantCache.cache.delete(self.lock_name)
      if (sts !~ %r!^DELETED!)
        e = LockInconsistency.new(self.lock_name,
                                  '/DELETED/',
                                  sts.inspect)
        raise e
      end
      return true
    end

    #
    # === Description
    # Fetch the value out of memcached.  Before being returned to the
    # called, the value is annotated with singleton methods intended
    # to keep the cache updated with any changes made to the value
    # we're returning.
    #
    # === Arguments
    # <i>None.</i>
    #
    # === Exceptions
    # [<tt>InstantCache::Destroyed</tt>] Cache value instance has been
    #                                    destroyed and is no longer usable.
    #                                    The value in the cache is unaffected.
    #
    def get
      raise Destroyed.new(self.name) if (self.destroyed?)
      #
      # TODO: Another instance of poor-man's-cache-location; see #reset
      #
      value = InstantCache.cache.get(self.name, self.rawmode)
      begin
        #
        # Make a copy of the thing we fetched out of the cache.
        #
        value.clone
        #
        # Add a note to it about who we are (so that requests can be
        # appropriately directed).
        #
        value.instance_variable_set(:@_instantcache_owner, self)
        #
        # Add the singleton annotations.
        #
        InstantCache.enwrap(value)
      rescue
        #
        # If the value was something we couldn't clone, like a Fixnum,
        # it's inherently immutable and we don't need to add no
        # steenkin' singleton methods to it.  That's our position
        # ayup.
        #
      end
      return value
    end
    alias_method(:read, :get)

    #
    # === Description
    # Store a value for the cell into the cache.  We need to remove
    # any singleton annotation methods before storing because the
    # memcache gem can't handle them (actually, Marshal#dump, which
    # memcache uses, cannot handle them).
    #
    # <i>N.B.:</i> We <b>don't</b> remove any annotations from the
    # original value; it might be altered again, in which case we'd
    # want to update the cache again.  This can lead to some odd
    # situations; see the bug list.
    #
    # === Arguments
    # [<i>val_p</i>] The new value to be stored.
    #
    # === Exceptions
    # [<tt>InstantCache::Destroyed</tt>] Cache value instance has been
    #                                    destroyed and is no longer usable.
    #                                    The value in the cache is unaffected.
    #
    def set(val_p)
      raise Destroyed.new(self.name) if (self.destroyed?)
      begin
        val = val_p.clone
      rescue TypeError => e
        val = val_p
      end
      #
      InstantCache.unwrap(val)
      #
      # TODO: Another instance of poor-man's-cache-location; see #reset
      #
      # We use both memcache#add and memcache#set for completeness.
      #
      InstantCache.cache.add(self.name, val, self.expiry, self.rawmode)
      InstantCache.cache.set(self.name, val, self.expiry, self.rawmode)
      #
      # Return the value as fetched through our accessor; this ensures
      # the proper annotation.
      #
      return self.get
    end
    alias_method(:write, :set)

    #
    # === Description
    # Return the string representaton of the value, not this instance.
    # This is part of our 'try to be transparent' sensitivity
    # training.
    #
    # === Arguments
    # Any appropriate to the #to_s method of the underlying data's class.
    #
    # === Exceptions
    # [<tt>InstantCache::Destroyed</tt>] Cache value instance has been
    #                                    destroyed and is no longer usable.
    #                                    The value in the cache is unaffected.
    #
    def to_s(*args)
      raise Destroyed.new(self.name) if (self.destroyed?)
      return self.get.__send__(:to_s, *args)
    end

  end                           # End of class Blob

  #
  # Class for integer-only memcache cells, capable of atomic
  # increment/decrement.  Basically the same as Blob, except with a
  # default reset value of zero and rawmode forced to true.
  #
  # However, counters have some additional features:
  # * They may only be set to integer values;
  # * <i><tt>varname</tt></i><tt>_increment</tt> and
  #   <i><tt>varname</tt></i><tt>_decrement</tt> methods, which provide access
  #   to the corresponding underlying memcache atomic integer
  #   operations;
  # * Decrementing stops at zero, and will not result in negative
  #   numbers (a feature of memcache).
  #
  class Counter < Blob

    class << self

      #
      # === Description
      # Access method declarator for an interlocked shared integer
      # memcache-backed variable.
      #
      # This declarator sets up several methods relating to the
      # variable.  If the name passed is <b><tt>:ivar</tt></b>, these
      # methods are created for it:
      #
      # [<i>ivar</i>]            Normal read accessor
      #                          (<i>e.g.</i>, <tt>obj.ivar</tt>).
      #                          (See Blob#get)
      # [<i>ivar</i>_reset]      Resets the cache variable to the default
      #                          'uninitialised' value.
      #                          (See Blob#reset)
      # [<i>ivar</i>_expiry]     Returns the current cache lifetime
      #                          (default 0).
      #                          (See Blob#expiry)
      # [<i>ivar</i>_expiry=]    Sets the cache lifetime.
      #                          (See Blob#expiry=)
      # [<i>ivar</i>_lock]       Tries to get an exclusive lock on the
      #                          variable.
      #                          (See Blob#lock)
      # [<i>ivar</i>_unlock]     Unlocks the variable if locked.
      #                          (See Blob#unlock)
      # [<i>ivar</i>_destroyed?] Returns true if variable is disconnected
      #                          from the cache and unusable.
      #                          (See Blob#destroyed?)
      # [<i>ivar</i>_destroy!]   Disconnects the variable from the cache
      #                          and makes it unusable.
      #                          (See Blob#destroy!)
      #
      # (These are the same methods created for a
      # Blob::memcached_accessor declaration.)
      #
      # In addition, the following counter-specific methods are created:
      #
      # [<i>ivar</i>_increment]  Adds the specified value to the cache
      #                          variable.
      #                          (See Counter#increment)
      # [<i>ivar</i>_incr]       Alias for
      #                          <i><tt>ivar</tt></i><tt>_increment</tt>.
      # [<i>ivar</i>_decrement]  Subtracts from the cache variable.
      #                          (See Counter#decrement)
      # [<i>ivar</i>_decr]       Alias for
      #                          <i><tt>ivar</tt></i><tt>_decrement</tt>.
      #
      # :call-seq:
      # memcached_counter(<i>symbol</i>[,...])
      # memcached_counter(<i>symbol</i>[,...]) { |symbol| ... }
      #
      # === Arguments
      # [<i>symbol</i>] As with other Ruby accessor declarations, the argument
      #                 list consists of one or more variable names represented
      #                 as symbols (<i>e.g.</i>, <tt>:variablename</tt>).
      # [<i>{block}</i>] If a block is supplied, its return value must
      #                  be a string, which will be used as the name of
      #                  the memcached cell backing the variable.  The
      #                  argument to the block is the name of the
      #                  variable as passed to the accessor declaration.
      #
      # === Exceptions
      # <i>None.</i>
      #
      #--
      # This will be overridden later, but we need to declare
      # *something* for the rdoc generation to work.
      #++
      def memcached_counter(*args, &block) ; end

    end                         # End of class Counter eigenclass
    #
    # When a cached 'counter' value is reset or cleared, that means
    # 'zero'.
    #
    RESET_VALUE = 0

    #
    # === Description
    # As with Blob#initialize, this is not intended to be called
    # directly.  Rather, instances are declared with the
    # #memcached_counter class method.
    #
    # :call-seq:
    # memcached_counter(<i>symbol</i>[,...])
    # memcached_counter(<i>symbol</i>[,...]) { |symbol| ... }
    #
    # === Arguments
    # [<i>symbol</i>] As with other Ruby accessor declarations, the argument
    #                 list consists of one or more variable names represented
    #                 as symbols (<i>e.g.</i>, <tt>:variablename</tt>).
    # :call-seq:
    # [<i>{block}</i>] If a block is supplied, its return value must
    #                  be a string, which will be used as the name of
    #                  the memcached cell backing the variable.  The
    #                  argument to the block is the name of the
    #                  variable as passed to the accessor declaration.
    #
    # === Exceptions
    # <i>None.</i>
    #
    def initialize(inival=nil)
      @rawmode = true
      return super
    end

    #
    # === Description
    # Fetch the cached value through the superclass, and convert it to
    # integer.  (Raw values get stored as strings, since they're
    # unmarshalled.)
    #
    # === Arguments
    # <i>None.</i>
    #
    # === Exceptions
    # [<tt>InstantCache::Destroyed</tt>] Cache value instance has been
    #                                    destroyed and is no longer usable.
    #                                    The value in the cache is unaffected.
    #                                    (From Blob#get)
    #
    def get
      return super.to_i
    end

    #
    # === Description
    # Store a value as an integer, and return the value as stored.
    # See Blob#set for the significance of this operation.
    #
    # === Arguments
    # [<i>val</i>] New value to be stored in the cached cell.
    #
    # === Exceptions
    # [<tt>InstantCache::CounterIntegerOnly</tt>] The supplied value
    #                                             was not an integer,
    #                                             and was not stored.
    # [<tt>InstantCache::Destroyed</tt>] Cache value instance has been
    #                                    destroyed and is no longer usable.
    #                                    The value in the cache is unaffected.
    #
    def set(val)
      unless (val.kind_of?(Integer))
        raise CounterIntegerOnly.new(self.ivar_name.inspect)
      end
      return super(val.to_i).to_i
    end

    #
    # === Description
    # Increment a memcached cell.  This <b>only</b> works in raw mode,
    # which is why it's in this class rather than Blob, but it's
    # implicitly atomic according to memcache semantics.
    #
    # :call-seq:
    # increment[(<i>by_amount</i>)] => <i>Integer</i>
    #
    # === Arguments
    # [<i>by_amount</i>] An integer amount by which to increase the
    #                    value of the variable; default is 1.
    #
    # === Exceptions
    # [<tt>InstantCache::CounterIntegerOnly</tt>] The supplied value
    #                                             was not an integer,
    #                                             and the cache was
    #                                             not changed.
    # [<tt>InstantCache::Destroyed</tt>] Cache value instance has been
    #                                    destroyed and is no longer usable.
    #                                    The value in the cache is unaffected.
    #
    def increment(amt=1)
      raise Destroyed.new(self.name) if (self.destroyed?)
      unless (amt.kind_of?(Integer))
        raise CounterIntegerOnly.new(self.ivar_name.inspect)
      end
      #
      # TODO: Another instance of poor-man's-cache-location; see #reset
      #
      return InstantCache.cache.incr(self.name, amt)
    end
    alias_method(:incr, :increment)

    #
    # === Description
    # Decrement a memcached cell.  This <b>only</b> works in raw mode,
    # which is why it's in this class rather than Blob, but it's
    # implicitly atomic according to memcache semantics.
    #
    # :call-seq:
    # decrement[(<i>by_amount</i>)] => <i>Integer</i>
    #
    # === Arguments
    # [<i>by_amount</i>] An integer amount by which to reduce the
    #                    value of the variable; default is 1.
    #
    # === Exceptions
    # [<tt>InstantCache::CounterIntegerOnly</tt>] The supplied value
    #                                             was not an integer,
    #                                             and the cache was
    #                                             not changed.
    # [<tt>InstantCache::Destroyed</tt>] Cache value instance has been
    #                                    destroyed and is no longer usable.
    #                                    The value in the cache is unaffected.
    #
    def decrement(amt=1)
      raise Destroyed.new(self.name) if (self.destroyed?)
      unless (amt.kind_of?(Integer))
        raise CounterIntegerOnly.new(self.ivar_name.inspect)
      end
      #
      # TODO: Another instance of poor-man's-cache-location; see #reset
      #
      return InstantCache.cache.decr(self.name, amt)
    end
    alias_method(:decr, :decrement)

  end                           # End of class Counter < Blob

  # :stopdoc:
  #
  # Back into the eigenclass to define the magic stuff that makes this
  # all work behind the scenes.
  #
  # TODO: All the '%' formatting and evaluations are really rather hokey..
  #
  class << self

    #
    # String constant used to set up most of the background magic
    # common to all of our types of cached variables.
    #
    # TODO: Resolve what to do if the instance variable is zapped
    #
    # One of the fortunate side-effects of all of the methods calling
    # this first is that if the instance variable gets zapped somehow,
    # the next access to it through of of our methods will create a
    # new Blob or Counter object and put it into the instance variable
    # before proceeding.
    #
    # One of the UNfortunate side effects of *that* is that if the
    # object that was lost was locked, it cannot be unlocked through
    # the normal paths -- only the blob object itself is supposed to
    # lock and unlock itself.  It can be worked around, but that's for
    # another day.
    #
    # If we decide against instantiating a new object, the ConnexionLost
    # exception is ready to be pressed into service.
    #
    Setup =<<-'EOT'             # :nodoc:
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
              InstantCache.cache.delete(mvar.name)
              InstantCache.cache.delete(mvar.send(:lock_name))
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

    #
    # String to define a read accessor for the given cache variable.
    #
    Reader =<<-'EOT'            # :nodoc:
      def %s
        self.__send__(:_initialise_%s)
        return @%s.get
      end
    EOT

    #
    # As above, except this is a storage (write) accessor, and is
    # optional.
    #
    Writer =<<-'EOT'            # :nodoc:
      def %s=(*args)
        self.__send__(:_initialise_%s)
        return @%s.set(*args)
      end
    EOT

    #
    # Canned string for declaring an integer counter cell.
    #
    Counter =<<-'EOT'           # :nodoc:
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

    #
    # Actual code to create a read accessor for a cell.
    #
    EigenReader = Proc.new { |*args,&block| # :nodoc:
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
        class_eval(Reader % subslist[7, 3])
      end
      nil
    }                           # End of Proc EigenReader

    #
    # Code for a write accessor.
    #
    EigenAccessor = Proc.new { |*args,&block| # :nodoc:
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
        class_eval(Reader % subslist[7, 3])
        class_eval(Writer % subslist[7, 3])
      end
      nil
    }                           # End of Proc EigenAccessor

    #
    # And the code for a counter (read and write access).
    #
    EigenCounter = Proc.new { |*args,&block| # :nodoc:
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
        class_eval(Reader % subslist[7, 3])
        class_eval(Writer % subslist[7, 3])
        class_eval(Counter % subslist[0, 10])
      end
      nil
    }                           # End of Proc EigenCounter

    #
    # === Description
    # This class method is invoked when the module is mixed into a
    # class; the argument is the class object involved.
    #
    # === Arguments
    # [<i>base_klass</i>] Class object of the class into which the
    #                     module is being mixed.
    #
    # === Exceptions
    # <i>None.</i>
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

  # :startdoc:

  #
  # === Description
  # This should be overridden by inheritors; it's used to form the name
  # of the memcached cell.
  #
  # === Arguments
  # <i>None.</i>
  #
  # === Exceptions
  # <i>None.</i>
  #
  def name
    return "Unnamed-#{self.class.name}-object"
  end                           # End of def name

end                             # End of module InstantCache
