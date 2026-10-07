# frozen_string_literal: true

class CSV
  # The error thrown when a field to be written violates
  # the configured spreadsheet text policy.
  #
  # The message includes the logical row number and the 1-based column
  # number of the offending field. The field value itself is not included
  # unless the policy was configured with <tt>expose_value: true</tt>.
  class SpreadsheetTextError < RuntimeError
    attr_reader :line_number, :column_number
    alias_method :lineno, :line_number

    def initialize(message, line_number, column_number)
      @line_number = line_number
      @column_number = column_number
      super("#{message} in column #{column_number} on line #{line_number}.")
    end
  end

  #
  # A CSV::SpreadsheetTextPolicy inspects String fields that are about to be
  # written and decides what to do with fields that a spreadsheet application
  # may interpret as a formula instead of as text (CSV formula injection).
  #
  # The policy is applied by CSV::Writer after write converters have run and
  # before CSV quoting, so neither +force_quotes+ nor output encodings can
  # bypass it. Only String fields are checked: a Numeric object such as
  # +-5+ is written as-is, while a user supplied String such as <tt>"-5"</tt>
  # is treated as text that a spreadsheet may misinterpret.
  #
  # A field is considered suspicious when, after ignoring the checked
  # leading whitespace and control characters (see below), it begins with
  # one of FORMULA_LEADING_CHARACTERS, or when it begins with one of the
  # checked control characters (some spreadsheet applications treat a
  # leading tab or carriage return as a formula trigger on their own).
  #
  # The checked character sets are deliberately small and explicit:
  #
  # - FORMULA_LEADING_CHARACTERS: <tt>=</tt>, <tt>+</tt>, <tt>-</tt>,
  #   <tt>@</tt>.
  # - CHECKED_LEADING_WHITESPACE: space (<tt>0x20</tt>) and horizontal tab
  #   (<tt>0x09</tt>).
  # - CHECKED_LEADING_CONTROL_CHARACTERS: carriage return (<tt>0x0D</tt>)
  #   and line feed (<tt>0x0A</tt>).
  #
  # These sets do not claim to cover every spreadsheet application;
  # different products normalize cell text differently. Configure a custom
  # policy object if you need a different rule set.
  #
  # Two actions are supported:
  #
  # - <tt>:reject</tt>: raise CSV::SpreadsheetTextError.
  # - <tt>:prefix</tt> (default): prepend +prefix+ (an apostrophe by
  #   default) so the cell is read as explicit text. A field that already
  #   starts with +prefix+ is left unchanged, so applying the policy twice
  #   never doubles the prefix.
  #
  class SpreadsheetTextPolicy
    # Characters that may start a formula when a cell begins with them.
    FORMULA_LEADING_CHARACTERS = ["=", "+", "-", "@"].freeze

    # Leading whitespace characters that are skipped before checking for
    # FORMULA_LEADING_CHARACTERS.
    CHECKED_LEADING_WHITESPACE = [" ", "\t"].freeze

    # Leading control characters that are skipped before checking for
    # FORMULA_LEADING_CHARACTERS, and that are suspicious on their own.
    CHECKED_LEADING_CONTROL_CHARACTERS = ["\r", "\n"].freeze

    # The default text prefix used by the <tt>:prefix</tt> action.
    DEFAULT_PREFIX = "'"

    # The default action, <tt>:prefix</tt>.
    DEFAULT_ACTION = :prefix

    attr_reader :action, :prefix

    # Normalizes an option value into a CSV::SpreadsheetTextPolicy instance
    # (or +nil+ when the policy is disabled):
    #
    # - +nil+ or +false+: disabled, returns +nil+.
    # - <tt>:reject</tt>: reject suspicious fields.
    # - <tt>:prefix</tt>: prefix suspicious fields with DEFAULT_PREFIX.
    # - \Hash: passed as keywords to ::new
    #   (e.g. <tt>{action: :prefix, prefix: "'"}</tt>).
    # - CSV::SpreadsheetTextPolicy: used as-is.
    def self.resolve(policy)
      case policy
      when nil, false
        nil
      when :reject
        new(action: :reject)
      when :prefix
        new(action: :prefix)
      when Hash
        new(**policy)
      when SpreadsheetTextPolicy
        policy
      else
        message = ":spreadsheet_text_policy must be nil, false, " +
                  ":reject, :prefix, a Hash, or a " +
                  "CSV::SpreadsheetTextPolicy: #{policy.inspect}"
        raise ArgumentError, message
      end
    end

    def initialize(action: DEFAULT_ACTION,
                   prefix: DEFAULT_PREFIX,
                   expose_value: false)
      unless [:reject, :prefix].include?(action)
        raise ArgumentError,
              "unknown spreadsheet text policy action: #{action.inspect}"
      end
      @action = action
      @prefix = String(prefix)
      @expose_value = expose_value ? true : false
      @prefix_bytes = @prefix.b
    end

    # Applies the policy to +field+, which is about to be written as column
    # +column_number+ (1-based) of logical row +line_number+.
    #
    # Returns the field to write (either +field+ itself or a prefixed copy);
    # raises CSV::SpreadsheetTextError when the action is <tt>:reject</tt>
    # and the field is suspicious.
    def apply(field, line_number, column_number)
      return field unless field.is_a?(String)
      return field if field.empty?
      return field unless suspicious?(field)

      case @action
      when :reject
        message = "field looks like a spreadsheet formula"
        message += ": #{field.inspect}" if @expose_value
        raise SpreadsheetTextError.new(message, line_number, column_number)
      else
        return field if already_prefixed?(field)
        encoded_prefix = @prefix.encode(field.encoding)
        encoded_prefix + field
      end
    end

    # Returns whether a spreadsheet application may interpret the given
    # String field as a formula. Non-String fields are never suspicious.
    def suspicious?(field)
      bytes = checkable_bytes(field)
      return false if bytes.empty?
      return true if formula_leading_byte?(bytes.getbyte(0))
      return true if control_byte?(bytes.getbyte(0))
      return false unless whitespace_byte?(bytes.getbyte(0))

      i = 0
      i += 1 while i < bytes.bytesize and skippable_byte?(bytes.getbyte(i))
      return false if i >= bytes.bytesize
      formula_leading_byte?(bytes.getbyte(i))
    end

    private

    # Returns a BINARY copy of +field+ in which the checked ASCII
    # characters are represented as themselves. For ASCII-compatible
    # encodings the raw bytes already satisfy this. For other encodings
    # (e.g. UTF-16) the field is transcoded first so that a non-default
    # encoding cannot hide a formula-looking field from the check.
    def checkable_bytes(field)
      if field.encoding.ascii_compatible?
        field.b
      else
        field.encode(Encoding::UTF_8).b
      end
    end

    def already_prefixed?(field)
      checkable_bytes(field).start_with?(@prefix_bytes)
    end

    def formula_leading_byte?(byte)
      byte == 0x3D or # =
        byte == 0x2B or # +
        byte == 0x2D or # -
        byte == 0x40    # @
    end

    def whitespace_byte?(byte)
      byte == 0x20 or byte == 0x09
    end

    def control_byte?(byte)
      byte == 0x0D or byte == 0x0A
    end

    def skippable_byte?(byte)
      whitespace_byte?(byte) or control_byte?(byte)
    end
  end
end
