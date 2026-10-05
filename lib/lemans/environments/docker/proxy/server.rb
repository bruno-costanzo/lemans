# frozen_string_literal: true

require "socket"
require "uri"

# An HTTP proxy that lets clients reach the allowed hosts only:
# CONNECT tunnels for https, absolute-form requests for plain http.
class AllowlistProxy
  HOP_HEADERS = /\A(?:connection|keep-alive|proxy-[\w-]+):/i

  def initialize(hosts, port: 3128)
    @hosts = hosts.map(&:downcase)
    @port = port
  end

  def run
    server = TCPServer.new("0.0.0.0", @port)
    $stdout.puts "listening on #{@port}: #{@hosts.join(", ")}"
    $stdout.flush
    Thread.report_on_exception = false
    loop { Thread.new(server.accept) { handle(it) } }
  end

  private

  def handle(client)
    head = client.gets("\r\n\r\n") or return
    request_line, *headers = head.split("\r\n")
    verb, target, version = request_line.split(" ", 3)

    verb == "CONNECT" ? tunnel(client, target) : forward(client, verb, target, version, headers)
  rescue SystemCallError, IOError, SocketError, URI::Error
    client.write("HTTP/1.1 502 Bad Gateway\r\n\r\n") rescue nil # rubocop:disable Style/RescueModifier
  ensure
    client.close
  end

  def tunnel(client, target)
    host, port = target.split(":", 2)
    return deny(client) unless allowed?(host)

    upstream = Socket.tcp(host, port.to_i, connect_timeout: 10)
    client.write("HTTP/1.1 200 Connection Established\r\n\r\n")
    pump(client, upstream)
  end

  # One request per connection: the upstream is told to close after the response.
  def forward(client, verb, target, version, headers)
    uri = URI(target)
    return deny(client) unless uri.is_a?(URI::HTTP) && allowed?(uri.host)

    upstream = Socket.tcp(uri.host, uri.port, connect_timeout: 10)
    headers = headers.grep_v(HOP_HEADERS)
    upstream.write("#{verb} #{uri.request_uri} #{version}\r\n#{headers.join("\r\n")}\r\nConnection: close\r\n\r\n")
    pump(client, upstream)
  end

  def allowed?(host) = @hosts.include?(host.to_s.downcase)

  def deny(client) = client.write("HTTP/1.1 403 Forbidden\r\n\r\n")

  def pump(client, upstream)
    Thread.new { copy(client, upstream) }
    copy(upstream, client)
  ensure
    upstream.close
  end

  # readpartial drains what gets already buffered, so a request body is not lost.
  def copy(from, to)
    loop { to.write(from.readpartial(65_536)) }
  rescue EOFError, IOError, SystemCallError
    nil
  ensure
    to.close_write rescue nil # rubocop:disable Style/RescueModifier
  end
end

AllowlistProxy.new(ARGV, port: Integer(ENV.fetch("PORT", "3128"))).run if $PROGRAM_NAME == __FILE__
