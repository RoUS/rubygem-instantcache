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

  class IncompleteException < InstantCache::Exception
    MessageFormat = [
                     'improperly-coded exception raised',
                     'improperly-coded exception "%s" raised',
                    ]
  end

  class Destroyed < InstantCache::Exception
    MessageFormat = [
                     'attempt to access destroyed variable',
                     'attempt to access destroyed variable "%s"',
                    ]
  end

  class LockInconsistency < InstantCache::Exception
    MessageFormat = [
                     'interlock cell inconsistency',
                     "interlock cell inconsistency\n" +
                     "\tcell='%s', expected='%s', actual='%s'",
                    ]
  end

end                             # End of module InstantCache
