# frozen_string_literal: true

require "test_helper"
require "socket"

load File.expand_path("../../../../../lib/lemans/environments/docker/proxy/server.rb", __dir__)

class AllowlistProxyTest < Minitest::Test
  def setup
    @origin = TCPServer.new("127.0.0.1", 0)
    @origin_thread = Thread.new do
      loop do
        client = @origin.accept
        request = client.gets("\r\n\r\n")
        request += client.read(request[/content-length: (\d+)/i, 1].to_i)
        client.write("HTTP/1.1 200 OK\r\nContent-Length: #{request.bytesize}\r\n\r\n#{request}")
        client.close
      end
    rescue IOError
      nil
    end

    @port = TCPServer.new("127.0.0.1", 0).then { |probe| probe.addr[1].tap { probe.close } }
    @proxy = Thread.new { capture_io { AllowlistProxy.new(%w[LocalHost], port: @port).run } }
    sleep 0.05 until listening?
  end

  def teardown
    @proxy.kill
    @origin.close
    @origin_thread.join
  end

  def test_tunnels_and_forwards_allowed_hosts_only
    origin = @origin.addr[1]

    tunnel = ask("CONNECT localhost:#{origin} HTTP/1.1\r\n\r\n")

    assert_equal "HTTP/1.1 200 Connection Established\r\n\r\n", tunnel.readpartial(1024)

    tunnel.write("ping\r\n\r\n")

    assert_includes tunnel.read, "\r\n\r\nping\r\n\r\n"

    forwarded = ask("POST http://localhost:#{origin}/hooks?x=1 HTTP/1.1\r\nHost: localhost\r\n" \
                    "Proxy-Connection: keep-alive\r\nContent-Length: 4\r\n\r\nbody").read

    assert_includes forwarded, "POST /hooks?x=1 HTTP/1.1\r\n"
    assert_includes forwarded, "Connection: close\r\n"
    assert_includes forwarded, "\r\n\r\nbody"
    refute_includes forwarded, "Proxy-Connection"

    assert_equal "HTTP/1.1 403 Forbidden\r\n\r\n", ask("CONNECT example.com:443 HTTP/1.1\r\n\r\n").read
    assert_equal "HTTP/1.1 403 Forbidden\r\n\r\n", ask("GET http://example.com/ HTTP/1.1\r\n\r\n").read
  end

  private

  def listening?
    TCPSocket.new("127.0.0.1", @port).close
    true
  rescue SystemCallError
    false
  end

  def ask(head)
    TCPSocket.new("127.0.0.1", @port).tap { it.write(head) }
  end
end
