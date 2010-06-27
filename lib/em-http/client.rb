# #--
# Copyright (C)2008 Ilya Grigorik
#
# Includes portion originally Copyright (C)2007 Tony Arcieri
# Includes portion originally Copyright (C)2005 Zed Shaw
# You can redistribute this under the terms of the Ruby
# license See file LICENSE for details
# #--

module EventMachine

  # A simple hash is returned for each request made by HttpClient with the
  # headers that were given by the server for that request.
  class HttpResponseHeader < Hash
    # The reason returned in the http response ("OK","File not found",etc.)
    attr_accessor :http_reason

    # The HTTP version returned.
    attr_accessor :http_version

    # The status code (as a string!)
    attr_accessor :http_status

    # E-Tag
    def etag
      self[HttpClient::ETAG]
    end

    def last_modified
      time = self[HttpClient::LAST_MODIFIED]
      time ? Time.parse(time) : nil
    end

    # HTTP response status as an integer
    def status
      Integer(http_status) rescue nil
    end

    # Length of content as an integer, or nil if chunked/unspecified
    def content_length
      @content_length ||= ((s = self[HttpClient::CONTENT_LENGTH]) &&
                           (s =~ /^(\d+)$/)) ? $1.to_i : nil
    end

    # Cookie header from the server
    def cookie
      self[HttpClient::SET_COOKIE]
    end

    # Is the transfer encoding chunked?
    def chunked_encoding?
      /chunked/i === self[HttpClient::TRANSFER_ENCODING]
    end

    def keep_alive?
      /keep-alive/i === self[HttpClient::KEEP_ALIVE]
    end

    def compressed?
      /gzip|compressed|deflate/i === self[HttpClient::CONTENT_ENCODING]
    end

    def location
      self[HttpClient::LOCATION]
    end
  end

  class HttpChunkHeader < Hash
    # When parsing chunked encodings this is set
    attr_accessor :http_chunk_size

    # Size of the chunk as an integer
    def chunk_size
      return @chunk_size unless @chunk_size.nil?
      @chunk_size = @http_chunk_size ? @http_chunk_size.to_i(base=16) : 0
    end
  end

  # Methods for building HTTP requests
  module HttpEncoding
    HTTP_REQUEST_HEADER="%s %s HTTP/1.1\r\n"
    FIELD_ENCODING = "%s: %s\r\n"

    # Escapes a URI.
    def escape(s)
      s.to_s.gsub(/([^ a-zA-Z0-9_.-]+)/n) {
        '%'+$1.unpack('H2'*$1.bytesize).join('%').upcase
      }.tr(' ', '+')
    end

    # Unescapes a URI escaped string.
    def unescape(s)
      s.tr('+', ' ').gsub(/((?:%[0-9a-fA-F]{2})+)/n){
        [$1.delete('%')].pack('H*')
      }
    end

    # Map all header keys to a downcased string version
    def munge_header_keys(head)
      head.inject({}) { |h, (k, v)| h[k.to_s.downcase] = v; h }
    end

    # HTTP is kind of retarded that you have to specify a Host header, but if
    # you include port 80 then further redirects will tack on the :80 which is
    # annoying.
    def encode_host
      if @uri.port == 80 || @uri.port == 443
        return @uri.host
      else
        @uri.host + ":#{@uri.port}"
      end
    end

    def encode_request(method, path, query, uri_query)
      HTTP_REQUEST_HEADER % [method.to_s.upcase, encode_query(path, query, uri_query)]
    end

    def encode_query(path, query, uri_query)
      encoded_query = if query.kind_of?(Hash)
        query.map { |k, v| encode_param(k, v) }.join('&')
      else
        query.to_s
      end
      if !uri_query.to_s.empty?
        encoded_query = [encoded_query, uri_query].reject {|part| part.empty?}.join("&")
      end
      return path if encoded_query.to_s.empty?
      "#{path}?#{encoded_query}"
    end

    # URL encodes query parameters:
    # single k=v, or a URL encoded array, if v is an array of values
    def encode_param(k, v)
      if v.is_a?(Array)
        v.map { |e| escape(k) + "[]=" + escape(e) }.join("&")
      else
        escape(k) + "=" + escape(v)
      end
    end

    # Encode a field in an HTTP header
    def encode_field(k, v)
      FIELD_ENCODING % [k, v]
    end

    # Encode basic auth in an HTTP header
    # In: Array ([user, pass]) - for basic auth
    #     String - custom auth string (OAuth, etc)
    def encode_auth(k,v)
      if v.is_a? Array
        FIELD_ENCODING % [k, ["Basic", Base64.encode64(v.join(":")).chomp].join(" ")]
      else
        encode_field(k,v)
      end
    end

    def encode_headers(head)
      head.inject('') do |result, (key, value)|
        # Munge keys from foo-bar-baz to Foo-Bar-Baz
        key = key.split('-').map { |k| k.to_s.capitalize }.join('-')
        result << case key
          when 'Authorization', 'Proxy-authorization'
            encode_auth(key, value)
          else
            encode_field(key, value)
        end
      end
    end

    def encode_cookie(cookie)
      if cookie.is_a? Hash
        cookie.inject('') { |result, (k, v)| result <<  encode_param(k, v) + ";" }
      else
        cookie
      end
    end
  end

  class HttpClient < Connection
    include EventMachine::Deferrable
    include HttpEncoding

    TRANSFER_ENCODING="TRANSFER_ENCODING".freeze
    CONTENT_ENCODING="CONTENT_ENCODING".freeze
    CONTENT_LENGTH="CONTENT_LENGTH".freeze
    KEEP_ALIVE="CONNECTION".freeze
    SET_COOKIE="SET_COOKIE".freeze
    LOCATION="LOCATION".freeze
    HOST="HOST".freeze
    LAST_MODIFIED="LAST_MODIFIED".freeze
    ETAG="ETAG".freeze
    CRLF="\r\n".freeze

    attr_accessor :method, :options, :uri
    attr_reader   :response, :response_header, :error, :redirects, :last_effective_url

    def post_init
      @max_duration_timer = nil
      @parser = HttpClientParser.new
      @data = EventMachine::Buffer.new
      @chunk_header = HttpChunkHeader.new
      @response_header = HttpResponseHeader.new
      @parser_nbytes = 0
      @response = nil
      @redirects = 0
      @errors = '' # both this and @error?
      @error = ''
      @last_effective_url = nil
      @content_decoder = nil
      @stream = nil
      @disconnect = nil
      @state = :response_header
      @bytes_received = 0
      @options = {}
    end

    # Simple getter, because @response is expected to be a String
    def response
      @response || ''
    end

    # start HTTP request once we establish connection to host
    def connection_completed
      # if connecting to proxy, then first negotiate the connection
      # to intermediate server and wait for 200 response
      if @options[:proxy] and @state == :response_header
        @state = :response_proxy
        send_request_header

        # if connecting via proxy, then state will be :proxy_connected,
        # indicating successful tunnel. from here, initiate normal http
        # exchange
      else
        if @options[:max_connection_duration] 
          @max_duration_timer = EM.add_timer(@options[:max_connection_duration]) {
            @aborted = true
            on_error("Max Connection Duration Exceeded (#{@options[:max_connection_duration]}s.)")
          }
        end
        @state = :response_header
        ssl = @options[:tls] || @options[:ssl] || {}
        start_tls(ssl) if @uri.scheme == "https" #or @uri.port == 443 # A user might not want https even on port 443.
        send_request_header
        send_request_body
      end
    end

    # request is done, invoke the callback
    def on_request_complete
      begin
        @content_decoder.finalize! if @content_decoder
      rescue HttpDecoders::DecoderError
        on_error "Content-decoder error"
      end

      close_connection
    end

    # request failed, invoke errback
    def on_error(msg, dns_error = false)
      @error = msg

      # no connection signature on DNS failures
      # fail the connection directly
      dns_error == true ? fail(self) : unbind
    end

    # assign a stream processing block
    def stream(&blk)
      @stream = blk
    end

    # assign disconnect callback for websocket
    def disconnect(&blk)
      @disconnect = blk
    end

    # raw data push from the client (WebSocket) should
    # only be invoked after handshake, otherwise it will
    # inject data into the header exchange
    #
    # frames need to start with 0x00-0x7f byte and end with
    # an 0xFF byte. Per spec, we can also set the first
    # byte to a value betweent 0x80 and 0xFF, followed by
    # a leading length indicator
    def send(data)
      if @state == :websocket
        send_data("\x00#{data}\xff")
      end
    end

    def normalize_body
      @normalized_body ||= begin
        if @options[:body].is_a? Hash
          @options[:body].to_params
        else
          @options[:body]
        end
      end
    end

    def websocket?; @uri.scheme == 'ws'; end

    def send_request_header
      query   = @options[:query]
      head    = @options[:head] ? munge_header_keys(@options[:head]) : {}
      file    = @options[:file]
      body    = normalize_body
      request_header = nil

      if @state == :response_proxy
        proxy = @options[:proxy]

        # initialize headers to establish the HTTP tunnel
        head = proxy[:head] ? munge_header_keys(proxy[:head]) : {}
        head['proxy-authorization'] = proxy[:authorization] if proxy[:authorization]
        request_header = HTTP_REQUEST_HEADER % ['CONNECT', "#{@uri.host}:#{@uri.port}"]

      elsif websocket?
        head['upgrade'] = 'WebSocket'
        head['connection'] = 'Upgrade'
        head['origin'] = @options[:origin] || @uri.host

      else
        # Set the Content-Length if file is given
        head['content-length'] = File.size(file) if file

        # Set the Content-Length if body is given
        head['content-length'] =  body.bytesize if body

        # Set the cookie header if provided
        if cookie = head.delete('cookie')
          head['cookie'] = encode_cookie(cookie)
        end

        # Set content-type header if missing and body is a Ruby hash
        if not head['content-type'] and options[:body].is_a? Hash
          head['content-type'] = "application/x-www-form-urlencoded"
        end
      end

      # Set the Host header if it hasn't been specified already
      head['host'] ||= encode_host

      # Set the User-Agent if it hasn't been specified
      head['user-agent'] ||= "EventMachine HttpClient"

      # Record last seen URL
      @last_effective_url = @uri

      # Build the request headers
      request_header ||= encode_request(@method, @uri.path, query, @uri.query)
      request_header << encode_headers(head)
      request_header << CRLF
      send_data request_header
    end

    def send_request_body
      if @options[:body]
        body = normalize_body
        send_data body
        return
      elsif @options[:file]
        stream_file_data @options[:file], :http_chunks => false
      end
    end

    def receive_data(data)
      @bytes_received += data.size
      if @options[:max_bytes].nil? or @options[:max_bytes] > @bytes_received
        @data << data
        dispatch
      else
        on_error("Bytes received exceeds limit (#{@bytes_received} vs. #{ @options[:max_bytes]})")
      end
    end

    # Called when part of the body has been read
    def on_body_data(data)
      if @content_decoder
        begin
          @content_decoder << data
        rescue HttpDecoders::DecoderError
          on_error "Content-decoder error"
        end
      else
        on_decoded_body_data(data)
      end
    end

    def on_decoded_body_data(data)
      if @stream
        @stream.call(data)
      else
        @response ||= ''
        @response << data
      end
    end

    def unbind
      EM.cancel_timer(@max_duration_timer) if @max_duration_timer

      if @last_effective_url != @uri and @redirects < @options[:redirects]
        # update uri to redirect location if we're allowed to traverse deeper
        @uri = @last_effective_url

        # keep track of the depth of requests we made in this session
        @redirects += 1

        # swap current connection and reassign current handler
        req = HttpOptions.new(@method, @uri, @options)
        reconnect(req.host, req.port)

        @response_header = HttpResponseHeader.new
        @state = :response_header
        @data.clear
      else
        if @state == :finished || (@state == :body && @bytes_remaining.nil? &&
            (!@options[:max_bytes] or @bytes_received < @options[:max_bytes]) &&
            (!@options[:max_connection_duration] or !@aborted))
          succeed(self)
        else
          @disconnect.call(self) if @state == :websocket and @disconnect
          fail(self)
        end
      end
    end

    #
    # Response processing
    #

    def dispatch
      while case @state
          when :response_proxy
            parse_response_header
          when :response_header
            parse_response_header
          when :chunk_header
            parse_chunk_header
          when :chunk_body
            process_chunk_body
          when :chunk_footer
            process_chunk_footer
          when :response_footer
            process_response_footer
          when :body
            process_body
          when :websocket
            process_websocket
          when :finished, :invalid
            break
          else raise RuntimeError, "invalid state: #{@state}"
        end
      end
    end

    def parse_header(header)
      return false if @data.empty?
      begin
        @parser_nbytes = @parser.execute(header, @data.to_str, @parser_nbytes)
      rescue EventMachine::HttpClientParserError
        @state = :invalid
        on_error "invalid HTTP format, parsing fails"
      end

      return false unless @parser.finished?

      # Clear parsed data from the buffer
      @data.read(@parser_nbytes)
      @parser.reset
      @parser_nbytes = 0

      true
    end

    def parse_response_header
      return false unless parse_header(@response_header)

      unless @response_header.http_status and @response_header.http_reason
        @state = :invalid
        on_error "no HTTP response"
        return false
      end

      if @state == :response_proxy
        # when a successfull tunnel is established, the proxy responds with a
        # 200 response code. from here, the tunnel is transparent.
        if @response_header.http_status.to_i == 200
          @response_header = HttpResponseHeader.new
          connection_completed
          return true
        else
          @state = :invalid
          on_error "proxy not accessible"
          return false
        end
      end

      # correct location header - some servers will incorrectly give a relative URI
      if @response_header.location
        begin
          location = URI.parse @response_header.location
          if location.relative?
            location = @uri.merge(location.to_s)
            @response_header[LOCATION] = location.to_s
          end

          # store last url on any sign of redirect
          @last_effective_url = location
        rescue
          on_error "Location header format error"
          return false
        end
      end

      # shortcircuit on HEAD requests
      if @method == "HEAD"
        @state = :finished
        unbind
      end

      if websocket?
        if @response_header.status == 101
          @state = :websocket
          succeed
        else
          fail "websocket handshake failed"
        end

      elsif @response_header.chunked_encoding?
        @state = :chunk_header
      elsif @response_header.content_length
        @state = :body
        @bytes_remaining = @response_header.content_length
      else
        @state = :body
        @bytes_remaining = nil
      end

      if decoder_class = HttpDecoders.decoder_for_encoding(response_header[CONTENT_ENCODING])
        begin
          @content_decoder = decoder_class.new do |s| on_decoded_body_data(s) end
        rescue HttpDecoders::DecoderError
          on_error "Content-decoder error"
        end
      end

      true
    end

    def parse_chunk_header
      return false unless parse_header(@chunk_header)

      @bytes_remaining = @chunk_header.chunk_size
      @chunk_header = HttpChunkHeader.new

      @state = @bytes_remaining > 0 ? :chunk_body : :response_footer
      true
    end

    def process_chunk_body
      if @data.size < @bytes_remaining
        @bytes_remaining -= @data.size
        on_body_data @data.read
        return false
      end

      on_body_data @data.read(@bytes_remaining)
      @bytes_remaining = 0

      @state = :chunk_footer
      true
    end

    def process_chunk_footer
      return false if @data.size < 2

      if @data.read(2) == CRLF
        @state = :chunk_header
      else
        @state = :invalid
        on_error "non-CRLF chunk footer"
      end

      true
    end

    def process_response_footer
      return false if @data.size < 2

      if @data.read(2) == CRLF
        if @data.empty?
          @state = :finished
          on_request_complete
        else
          @state = :invalid
          on_error "garbage at end of chunked response"
        end
      else
        @state = :invalid
        on_error "non-CRLF response footer"
      end

      false
    end

    def process_body
      if @bytes_remaining.nil?
        on_body_data @data.read
        return false
      end

      if @bytes_remaining.zero?
        @state = :finished
        on_request_complete
        return false
      end

      if @data.size < @bytes_remaining
        @bytes_remaining -= @data.size
        on_body_data @data.read
        return false
      end

      on_body_data @data.read(@bytes_remaining)
      @bytes_remaining = 0

      # If Keep-Alive is enabled, the server may be pushing more data to us
      # after the first request is complete. Hence, finish first request, and
      # reset state.
      if @response_header.keep_alive?
        @data.clear # hard reset, TODO: add support for keep-alive connections!
        @state = :finished
        on_request_complete

      else
        if @data.empty?
          @state = :finished
          on_request_complete
        else
          @state = :invalid
          on_error "garbage at end of body"
        end
      end

      false
    end

    def process_websocket
      return false if @data.empty?

      # slice the message out of the buffer and pass in
      # for processing, and buffer data otherwise
      buffer = @data.read
      while msg = buffer.slice!(/\000([^\377]*)\377/)
        msg.gsub!(/^\x00|\xff$/, '')
        @stream.call(msg)
      end

      # store remainder if message boundary has not yet
      # been received
      @data << buffer if not buffer.empty?

      false
    end
  end

end
