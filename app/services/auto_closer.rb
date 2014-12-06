class AutoCloser
  attr_reader :topic

  class TimeParser
    class Error < StandardError; end
    attr_reader :arg

    class TimeParsed < Struct.new(:at, :hours)
      include Comparable
      extend Forwardable
      def_delegator :at, :<=>

      def past?
        at && at < Time.zone.now
      end

    end

    # Valid arguments for the auto close time:
    #  * An integer, which is the number of hours from now to close the topic.
    #  * A time, like "12:00", which is the time at which the topic will close in the current day
    #    or the next day if that time has already passed today.
    #  * A timestamp, like "2013-11-25 13:00", when the topic should close.
    #  * A timestamp with timezone in JSON format. (e.g., "2013-11-26T21:00:00.000Z")
    #  * nil, to prevent the topic from automatically closing.
    def initialize(arg, on_error = Proc.new {})
      @arg = arg
      @on_error = on_error
    end

    def call
      parse_string or parse_number
      handle_errors

      time
    end

    private

    def handle_errors
      @on_error.call if time.past?
    end

    def parse_number
      if (num_hours = arg.to_f) > 0
        time.at = num_hours.hours.from_now
        time.hours = num_hours
      end
    end

    def parse_string
      if arg.is_a?(String)
        parse_time or parse_datetime
      end
    end

    def parse_datetime
      if arg.include?("-")
        time.at = Time.zone.parse(arg)
      end
    end

    def parse_time
      if m = /^(\d{1,2}):(\d{2})(?:\s*[AP]M)?$/i.match(arg.strip)
        now = Time.zone.now
        time.at = Time.zone.local(now.year, now.month, now.day, m[1].to_i, m[2].to_i)
        time.at += 1.day if time.past?
        time.at
      end
    end

    def time
      @time ||= TimeParsed.new
    end
  end

  def initialize(topic)
    @topic = topic
    @topic.auto_close_at = @topic.auto_close_hours = nil
  end

  def by_time(arg)
    close_time = TimeParser.new(arg, on_error).call

    based_on_last_post(close_time) or generic(close_time) or clear
    topic.auto_close_hours = close_time.hours

    self
  end

  def by_user(user)
    if topic.auto_close_at
      if user.try(:staff?) || user.try(:trust_level) == TrustLevel[4]
        topic.auto_close_user = user
      else
        topic.auto_close_user ||= (topic.user.staff? || topic.user.trust_level == TrustLevel[4] ? topic.user : Discourse.system_user)
      end
    end

    self
  end

  private

  def based_on_last_post(close_time)
    if topic.auto_close_based_on_last_post && close_time.hours > 0
      topic.auto_close_at = topic.last_post_created_at + close_time.hours.hours
      topic.auto_close_started_at = Time.zone.now
    end
  end

  def generic(close_time)
    if close_time.at
      topic.auto_close_at = close_time.at
      topic.auto_close_started_at ||= Time.zone.now
    end
  end

  def clear
    topic.auto_close_started_at = nil
  end


  def on_error
    Proc.new { topic.errors.add(:auto_close_at, :invalid) }
  end
end
