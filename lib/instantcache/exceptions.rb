module InstantCache

  class Exception < StandardError

    def initialize(*args)
      @appargs = args.dup
      super(args[0])
      unless (self.class.constants.include?('MessageFormat'))
        raise IncompleteException.new(self.class.name)
      end
    end

    def message
      if (self.class.constants.include?('MessageFormat'))
        fmt = self.class::MessageFormat[@appargs.empty? ? 0 : 1]
        return fmt % [ *@appargs ]
      end
      return @message
    end

    def to_s
      return self.message
    end

  end

  #
  # Some exception was raised with the wrong arguments.
  #
  class IncompleteException < InstantCache::Exception
    MessageFormat = [
                     'improperly-coded exception raised',
                     'improperly-coded exception "%s" raised',
                    ]
  end

  #
  # Once a variable has been hit by the 'destroy!' method, it
  # becomes inaccessible to the instance.
  #
  class Destroyed < InstantCache::Exception
    MessageFormat = [
                     'attempt to access destroyed variable',
                     'attempt to access destroyed variable "%s"',
                    ]
  end

  #
  # Our record of the locked status of a cell differs from the information
  # stored in the memcache about it.
  #
  class LockInconsistency < InstantCache::Exception
    MessageFormat = [
                     'interlock cell inconsistency',
                     "interlock cell inconsistency\n" +
                     "\tcell='%s', expected='%s', actual='%s'",
                    ]
  end

  #
  # User-supplied names are only permitted for shared variables;
  # otherwise private ones may get inadvertently shared and bollixed.
  #
  class SharedOnly < InstantCache::Exception
    MessageFormat = [
                     'custom names are only permitted for shared variables',
                     'custom names are only permitted for shared variables; ' +
                     "'%s' is labelled as private",
                    ]
  end

end                             # End of module InstantCache
