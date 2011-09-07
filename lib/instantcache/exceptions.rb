# -*- coding: utf-8 -*-
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

module InstantCache

  #
  # = InstantCache exceptions
  #
  # Author::      Ken Coar
  # Copyright::   Copyright © 2011 Ken Coar
  # License::     Apache Licence 2.0
  #
  # == Description
  #
  # InstantCache reports problems using Ruby's exception mechanism.  Its
  # exceptions are a little different from the usual run-of-the-mill
  # ones, however.  Each exception declaration (aside from the
  # superclass) consists solely of a constant named
  # <tt>MessageFormat</tt>, which is a two-element array of strings.
  # The first element is the default text of the message, which is used
  # when the exception is raised without arguments.  <i>E.g.</i>,
  #
  #   raise InstantCache::Destroyed
  #
  # The second element of the <tt>MessageFormat</tt> array is utilised
  # when a new instance of the exception is created, and the
  # constructor's arguments are used as <tt>sprintf</tt>-style arguments
  # with the <tt>MessageFormat</tt> text.
  #

  #
  # The superclass for all of the InstantCache exceptions.  It
  # provides all the infrastructure needed by the individual specific
  # exceptions.
  #
  class Exception < StandardError

    #
    # === Description
    #
    # As the superclass, this exception is not intended for direct invocation.
    #
    # === Arguments
    # N/A
    #
    # === Exceptions
    # [<tt>InstantCache::IncompleteException</tt>] This class was
    #                                              subclassed, but the
    #                                              subclass didn't
    #                                              declare the
    #                                              requisite
    #                                              <tt>MessageFormat</tt>
    #                                              constant.
    #
    def initialize(*args)
      @appargs = args.dup
      super(args[0])
      unless (self.class.constants.include?('MessageFormat'))
        raise IncompleteException.new(self.class.name)
      end
    end                         # End of def initialize

    #
    # === Description
    # This is an override of the standard exception <tt>message</tt>
    # method, enhanced to deal with our with-or-without-arguments
    # invocation decision mechanism.
    #
    # If the current class has a <b><tt>MessageFormat</tt></b>
    # constant array defined, the first element will be used for the
    # exception message if no arguments were passed to the invocation.
    # Otherwise, the second element of the <tt>MessageFormat</tt>
    # array will be treated as a '%' format string and the invocation
    # arguments as input to the formatting process, the result of
    # which becomes the exception message string.
    #
    # === Arguments
    # <i>None.</i>
    #
    # === Exceptions
    # <i>None.</i>
    #
    def message
      if (self.class.constants.include?('MessageFormat'))
        fmt = self.class::MessageFormat[@appargs.empty? ? 0 : 1]
        return fmt % [ *@appargs ]
      end
      return @message
    end                         # End of def message

    #
    # === Description
    # Return the message text of the exception as a string, after
    # applying any appropriate formating.
    #
    # === Arguments
    # <i>None.</i>
    #
    # === Exceptions
    # <i>None.</i>
    #
    def to_s
      return self.message
    end                         # End of def to_s

  end                           # End of class Exception

  #
  # Some exception was raised with the wrong arguments.
  #
  class IncompleteException < InstantCache::Exception
    #
    # ==== <tt>raise IncompleteException</tt>
    #   => InstantCache::IncompleteException: improperly-coded exception raised
    #
    # ==== <tt>raise IncompleteException.new('<i>arg</i>')</tt>
    #   => InstantCache::IncompleteException: improperly-coded exception "arg" raised
    #   
    MessageFormat = [
                     'improperly-coded exception raised',
                     'improperly-coded exception "%s" raised',
                    ]
  end                           # End of class IncompleteException

  #
  # Once a variable has been hit by the 'destroy!' method, it
  # becomes inaccessible to the instance.
  #
  class Destroyed < InstantCache::Exception
    #
    # ==== <tt>raise Destroyed</tt>
    #   => InstantCache::Destroyed: attempt to access destroyed variable
    #
    # ==== <tt>raise Destroyed.new('<i>arg</i>')</tt>
    #   => InstantCache::Destroyed: attempt to access destroyed variable "arg"
    #   
    MessageFormat = [
                     'attempt to access destroyed variable',
                     'attempt to access destroyed variable "%s"',
                    ]
  end                           # End of class Destroyed

  #
  # Our record of the locked status of a cell differs from the information
  # stored in the memcache about it.  This Is Not Good.
  #
  class LockInconsistency < InstantCache::Exception
    #
    # ==== <tt>raise LockInconsistency</tt>
    #   => InstantCache::LockInconsistency: interlock cell inconsistency
    #
    # ==== <tt>raise LockInconsistency.new('<i>name</i>', '<i>true</i>', '<i>false</i>')</tt>
    #   => InstantCache::LockInconsistency: interlock cell inconsistency
    #             cell='name', expected='true', actual='false'
    #   
    MessageFormat = [
                     'interlock cell inconsistency',
                     "interlock cell inconsistency\n" +
                     "\tcell='%s', expected='%s', actual='%s'",
                    ]
  end                           # End of class LockInconsistency

  #
  # User-supplied names are only permitted for shared variables;
  # otherwise private ones may get inadvertently shared and bollixed.
  #
  class SharedOnly < InstantCache::Exception
    #
    # ==== <tt>raise SharedOnly</tt>
    #   => InstantCache::SharedOnly: custom names are only permitted for shared variables
    #
    # ==== <tt>raise SharedOnly.new('<i>name</i>')</tt>
    #   => InstantCache::SharedOnly: custom names are only permitted for shared variables; 'name' is labelled as private
    #   
    MessageFormat = [
                     'custom names are only permitted for shared variables',
                     ('custom names are only permitted for shared variables; ' +
                      "'%s' is labelled as private"),
                    ]
  end                           # End of class SharedOnly

  #
  # Counter variables are only permitted to be frobbed with integers.
  # We gritch if anything else is attempted.
  #
  class CounterIntegerOnly < InstantCache::Exception
    #
    # ==== <tt>raise CounterIntegerOnly</tt>
    #   => InstantCache::CounterIntegerOnly: variables declared as counters are integer-only
    #
    # ==== <tt>raise CounterIntegerOnly.new('<i>name</i>')</tt>
    #   => InstantCache::CounterIntegerOnly: variables declared as counters are integer-only: name
    #   
    MessageFormat = [
                     'variables declared as counters are integer-only',
                     'variables declared as counters are integer-only: %s',
                    ]
  end                           # End of class CounterIntegerOnly

  #
  # Because of the annotation of returned values with callback singleton
  # methods, it's possible for multiple user variables to hold references
  # to a cell.  <i>E.g.</i>, one might remember the cell as a hash and
  # modify an element, even though the cell has actually be explicitly
  # set to something else.  This exception is raised if there's a mismatch
  # when an annotation tries to update the cell.
  #
  # TODO: This is not working properly yet.
  #
  class IncompatibleType < InstantCache::Exception
    #
    # ==== <tt>raise IncompatibleType</tt>
    #   => InstantCache::IncompatibleType: variable class incompatible with cached value
    #
    # ==== <tt>raise IncompatibleType.new('<i>Hash</i>', '<i>Array</i>', '<i>name</i>')</tt>
    #   => InstantCache::IncompatibleType: variable class "Hash" incompatible with class "Array" of cached variable "name"',
    #   
    MessageFormat = [
                     'variable class incompatible with cached value',
                     'variable class "%s" incompatible with class "%s" ' +
                     'of cached variable "%s"',
                    ]
  end                           # End of class IncompatibleType

end                             # End of module InstantCache
