# frozen_string_literal: true

class CSV
  # Note: Don't use this class directly. This is an internal class.
  #
  # A CSV::SpreadsheetTextPolicy decides how the writer treats String
  # fields whose text a spreadsheet application may interpret as a
  # formula instead of as literal text.
  #
  # A field is considered dangerous when, after skipping any leading
  # characters in SKIPPED_LEADING_CHARACTERS, its first character is in
  # FORMULA_CHARACTERS. Only String fields are checked; other objects
  # (including Numeric values such as Integer and Float) are passed
  # through unchanged, so a real number is never confused with a
  # user-supplied String that merely looks like one.
  #
  # The checked character sets are a conservative, documented
  # convention; they do not claim to cover the formula syntax of every
  # spreadsheet application.
  class SpreadsheetTextPolicy
    # Leading characters that some spreadsheet applications treat as
    # the start of a formula when one is the first character of a cell.
    FORMULA_CHARACTERS = ["=", "+", "-", "@"].freeze

    # Leading whitespace and control characters that some spreadsheet
    # applications skip before deciding whether a cell holds a formula:
    #
    # - Space (U+0020)
    # - Horizontal tab (U+0009)
    # - Line feed (U+000A)
    # - Vertical tab (U+000B)
    # - Form feed (U+000C)
    # - Carriage return (U+000D)
    SKIPPED_LEADING_CHARACTERS = [" ", "\t", "\n", "\v", "\f", "\r"].freeze

    # Matches a String whose first non-skipped character is a formula
    # character.
    DANGEROUS_PATTERN = /\A[ \t\n\v\f\r]*[=+\-@]/

    # The default text prefix prepended by the +:prefix+ action.
    DEFAULT_PREFIX = "'"

    # Builds a policy from an option value; returns nil for nil.
    #
    # Accepted values:
    # - nil: no policy (checking disabled).
    # - :reject: reject dangerous fields with CSV::SpreadsheetTextError.
    # - :prefix: prepend DEFAULT_PREFIX to dangerous fields.
    # - Hash: passed to ::new as keyword arguments
    #   (+action:+, +prefix:+, +expose_value:+).
    def self.build(spec, option_name)
      case spec
      when nil
        nil
      when SpreadsheetTextPolicy
        spec
      when :reject
        new(action: :reject)
      when :prefix
        new(action: :prefix)
      when Hash
        new(**spec)
      else
        message = "#{option_name} must be :reject, :prefix, a Hash, or nil: " +
                  spec.inspect
        raise ArgumentError, message
      end
    end

    attr_reader :action, :prefix

    def initialize(action: :prefix, prefix: DEFAULT_PREFIX, expose_value: false)
      unless action == :reject or action == :prefix
        message = ":action must be :reject or :prefix: #{action.inspect}"
        raise ArgumentError, message
      end
      if action == :prefix and
         not (prefix.is_a?(String) and not prefix.empty?)
        message = ":prefix must be a non-empty String: #{prefix.inspect}"
        raise ArgumentError, message
      end
      @action = action
      @prefix = prefix
      @expose_value = expose_value ? true : false
    end

    # Applies the policy to +field+, which is the value of the field at
    # 0-based column +index+ on logical line +lineno+ of the output.
    #
    # Returns the field unchanged when it is not a dangerous String;
    # returns the prefixed field for the +:prefix+ action; raises
    # CSV::SpreadsheetTextError for the +:reject+ action.
    def apply(field, index, lineno)
      return field unless field.is_a?(String)
      return field unless dangerous?(field)

      case @action
      when :reject
        message = "Dangerous spreadsheet text"
        message += ": #{field.inspect}" if @expose_value
        raise SpreadsheetTextError.new(message, lineno, index)
      when :prefix
        prefix = @prefix
        unless field.encoding == prefix.encoding
          prefix = prefix.encode(field.encoding)
        end
        # A field that already carries the prefix is left as-is, so
        # re-processing a row never stacks prefixes.
        return field if field.start_with?(prefix)
        prefix + field
      end
    end

    private
    def dangerous?(field)
      # Compare in UTF-8 so that the field's own encoding (including
      # ASCII-incompatible ones such as UTF-16) cannot hide dangerous
      # leading characters; invalid bytes are replaced rather than
      # raising.
      text = field.encode(Encoding::UTF_8,
                          invalid: :replace,
                          undef: :replace)
      DANGEROUS_PATTERN.match?(text)
    end
  end
end
