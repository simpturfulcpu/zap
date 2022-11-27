{% if flag?(:preview_mt) %}
  struct SafeSet(T)
    property inner : Set(T)
    getter lock = Mutex.new

    def initialize(*args, **kwargs)
      @inner = Set(T).new(*args, **kwargs)
    end

    macro method_missing(call)
    @lock.synchronize do
      @inner.\{{call}}
    end
  end
  end
{% else %}
  alias SafeSet = Set
{% end %}
