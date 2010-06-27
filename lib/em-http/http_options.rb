class HttpOptions
  attr_reader :uri, :method, :host, :port, :options

  def initialize(method, uri, options)
    raise ArgumentError, "invalid request path" unless /^\// === uri.path

    @options = options
    @method = method.to_s.upcase
    @uri = uri

    if proxy = options[:proxy]
      @host = proxy[:host]
      @port = proxy[:port]
    else
      @host = uri.host
      @port = uri.port
    end

    @options[:timeout]    ||= 10  # default connect & inactivity timeouts
    @options[:redirects]  ||= 0   # default number of redirects to follow

    # Make sure the ports are set as Addressable::URI doesn't
    # set the port if it isn't there
    if uri.scheme == "https"
      @uri.port ||= 443
      @port     ||= 443
    else
      @uri.port ||= 80
      @port     ||= 80
    end
  end
end