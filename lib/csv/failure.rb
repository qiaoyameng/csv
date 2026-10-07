# frozen_string_literal: true

class CSV
  #
  # A CSV::Failure represents a record that could not be imported while
  # parsing in recovery mode (see CSV.import and the <tt>:recover</tt> option).
  #
  # It preserves the bad record for manual inspection:
  # - #lineno:: the 1-based logical line number of the failed record
  #   (one logical record per count, even when it spans several physical
  #   lines because of quoted fields).
  # - #byte_range:: the byte offset Range covered by the record in the
  #   original input, including its row separator when present.
  # - #raw:: the raw bytes of the record, possibly truncated to
  #   <tt>:max_failure_bytes</tt>.
  # - #truncated?:: whether #raw was truncated.
  # - #error:: the exception that caused the record to fail.
  # - #reason:: the human readable error message.
  #
  class Failure
    # Returns the 1-based logical line number of the failed record.
    attr_reader :lineno

    # Returns the byte offset Range covered by the record in the input.
    attr_reader :byte_range

    # Returns the (possibly truncated) raw bytes of the record.
    attr_reader :raw

    # Returns the exception that caused the failure.
    attr_reader :error

    # Returns +true+ if the retained raw bytes were truncated.
    def truncated?
      @truncated
    end

    # Returns the number of raw bytes that were retained.
    def raw_bytesize
      @raw.bytesize
    end

    # Returns the first byte offset of the record in the input.
    def start_byte
      @byte_range.begin
    end

    # Returns the exclusive end byte offset of the record in the input.
    def end_byte
      @byte_range.exclude_end? ? @byte_range.end : @byte_range.end + 1
    end

    # Returns the human readable error message for the failed record.
    # Any internal parser line reference is normalized to the record's
    # logical line number.
    def reason
      @error.message.sub(/ in line \d+\.\z/, " in line #{lineno}.")
    end

    def initialize(lineno:, byte_range:, raw:, error:, truncated: false) # :nodoc:
      @lineno = lineno
      @byte_range = byte_range
      @raw = raw
      @error = error
      @truncated = truncated
      freeze
    end

    def inspect
      "#<#{self.class.name} lineno:#{lineno} byte_range:#{byte_range} " \
      "truncated:#{truncated?} reason:#{reason.inspect}>"
    end

    alias_method :to_s, :inspect
  end

  #
  # Raised in recovery mode when a record boundary cannot be determined and
  # parsing must stop.  This happens for:
  # - An unclosed quoted field (the quoted field consumes the rest of input).
  # - Exceeding the configured rescan budget while searching for a
  #   record boundary.
  #
  class UnrecoverableMalformedCSVError < MalformedCSVError
    # Returns the byte offset at which scanning gave up, when available.
    attr_reader :byte_offset

    def initialize(message, line_number, byte_offset = nil)
      @byte_offset = byte_offset
      message = message.sub(/ in line \d+\.\z/, "")
      super(message, line_number)
    end
  end
end
