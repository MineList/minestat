require_relative 'test_helper'

class MineStatSrvHarness < MineStat
  private

  def resolve_srv
    @srv_address = 'backend.example.test'
    @srv_port = 25_570
    true
  end
end

class MineStatAddressResolutionHarness < MineStat
  private

  def resolve_a
    @resolved_ip = '93.184.216.34'
    true
  end
end

class MineStatConnectionTargetTest < Minitest::Test
  include HandshakeDecoder

  def test_tcp_uses_pinned_literal_and_preserves_hostname_handshake
    socket = FakeJsonSocket.new(status_payload)
    socket_args = nil

    TCPSocket.stub(:new, lambda { |*args|
      socket_args = args
      socket
    }) do
      result = MineStat.new(
        'play.example.test',
        25_565,
        resolved_ip: '93.184.216.34',
        request_type: MineStat::Request::JSON,
        srv_enabled: false,
        timeout: 1
      )

      assert_equal true, result.online
    end

    assert_equal ['93.184.216.34', 25_565], socket_args
    assert_equal 'play.example.test', decode_handshake(socket.writes.first)[:host]
    assert_equal 25_565, decode_handshake(socket.writes.first)[:port]
  end

  def test_tcp_uses_pinned_literal_and_preserves_srv_handshake
    socket = FakeJsonSocket.new(status_payload)
    socket_args = nil

    TCPSocket.stub(:new, lambda { |*args|
      socket_args = args
      socket
    }) do
      result = MineStatSrvHarness.new(
        'play.example.test',
        25_565,
        resolved_ip: '93.184.216.35',
        request_type: MineStat::Request::JSON,
        srv_enabled: true,
        timeout: 1
      )

      assert_equal true, result.online
    end

    assert_equal ['93.184.216.35', 25_570], socket_args
    assert_equal 'backend.example.test', decode_handshake(socket.writes.first)[:host]
    assert_equal 25_570, decode_handshake(socket.writes.first)[:port]
  end

  def test_udp_uses_pinned_literal
    socket = Minitest::Mock.new
    socket.expect(:connect, nil, ['93.184.216.36', 19_132])

    UDPSocket.stub(:new, socket) do
      result = build_connect_harness(
        address: 'bedrock.example.test',
        port: 19_132,
        resolved_ip: '93.184.216.36',
        request_type: MineStat::Request::BEDROCK
      ).send(:connect)

      assert_equal MineStat::Retval::SUCCESS, result
    end

    socket.verify
  end

  def test_udp_uses_ipv6_socket_for_ipv6_pin
    socket = Minitest::Mock.new
    socket.expect(:connect, nil, ['2001:db8::1', 19_132])
    socket_family = nil

    UDPSocket.stub(:new, lambda { |family = nil|
      socket_family = family
      socket
    }) do
      result = build_connect_harness(
        address: 'bedrock.example.test',
        port: 19_132,
        resolved_ip: '2001:db8::1',
        request_type: MineStat::Request::BEDROCK
      ).send(:connect)

      assert_equal MineStat::Retval::SUCCESS, result
    end

    assert_equal Socket::AF_INET6, socket_family
    socket.verify
  end

  def test_hostname_fallback_remains_when_literal_is_not_provided
    socket = FakeJsonSocket.new(status_payload)
    socket_args = nil

    TCPSocket.stub(:new, lambda { |*args|
      socket_args = args
      socket
    }) do
      result = MineStatAddressResolutionHarness.new(
        'play.example.test',
        25_565,
        request_type: MineStat::Request::JSON,
        srv_enabled: false,
        timeout: 1
      )

      assert_equal true, result.online
    end

    assert_equal ['play.example.test', 25_565], socket_args
  end

  def test_resolved_ip_rejects_hostnames
    error = assert_raises(ArgumentError) do
      MineStat.new(
        'play.example.test',
        25_565,
        resolved_ip: 'other.example.test',
        request_type: MineStat::Request::JSON,
        srv_enabled: false
      )
    end

    assert_equal 'resolved_ip must be a literal IP address', error.message
  end

  def test_resolved_ip_rejects_cidr_ranges
    error = assert_raises(ArgumentError) do
      MineStat.new(
        'play.example.test',
        25_565,
        resolved_ip: '8.8.8.8/0',
        request_type: MineStat::Request::JSON,
        srv_enabled: false
      )
    end

    assert_equal 'resolved_ip must be a literal IP address', error.message
  end

  private

  def build_connect_harness(address:, port:, resolved_ip:, request_type:)
    instance = MineStat.allocate
    instance.instance_variable_set(:@address, address)
    instance.instance_variable_set(:@port, port)
    instance.instance_variable_set(:@connection_ip, resolved_ip)
    instance.instance_variable_set(:@resolved_ip, resolved_ip)
    instance.instance_variable_set(:@request_type, request_type)
    instance.instance_variable_set(:@srv_enabled, false)
    instance.instance_variable_set(:@srv_succeeded, false)
    instance.instance_variable_set(:@debug, false)
    instance
  end
end
