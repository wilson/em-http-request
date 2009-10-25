require 'eventmachine'
require 'em-http'

urls = ARGV
if urls.size < 1
  puts "Usage: #{$0} <url> <url> <...>"
  exit
end

pending = urls.size

EM.run do
  urls.each do |url|
    http = EM::HttpRequest.new(url).get
    http.callback {
      puts "#{url}\n#{http.response_header.status} - #{http.response.length} bytes"

      pending -= 1
      EM.stop if pending < 1
    }
    http.errback {
      puts "#{url}\n" + http.errors.join("\n")

      pending -= 1
      EM.stop if pending < 1
    }
  end
end
