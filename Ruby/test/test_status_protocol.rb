require 'json'
require 'minitest/autorun'
require_relative '../lib/minestat'

class FakeJsonSocket
  attr_reader :writes

  def initialize(json_payload)
    @writes = []
    @read_buffer = +""
    @recv_buffer = json_payload.dup

    packet_id = pack_varint(0)
    json_len = pack_varint(json_payload.bytesize)
    total_len = pack_varint(packet_id.bytesize + json_len.bytesize + json_payload.bytesize)

    @read_buffer << total_len
    @read_buffer << packet_id
    @read_buffer << json_len
  end

  def write(data)
    @writes << data
    data.bytesize
  end

  def flush
  end

  def close
  end

  def read(length)
    return nil if @read_buffer.empty?

    chunk = @read_buffer.byteslice(0, length)
    @read_buffer = @read_buffer.byteslice(length..-1) || +""
    chunk
  end

  def recv(length, _flags = nil)
    chunk = @recv_buffer.byteslice(0, length) || +""
    @recv_buffer = @recv_buffer.byteslice(length..-1) || +""
    chunk
  end

  private

  def pack_varint(value)
    value &= 0xFFFFFFFF
    buf = +""
    loop do
      byte = value & 0x7F
      value >>= 7
      if value != 0
        buf << (byte | 0x80).chr
      else
        buf << byte.chr
        break
      end
    end
    buf
  end
end

class MineStatProtocolHarness < MineStat
  attr_reader :captured_socket

  def initialize(options = {}, json_response_protocol: 760)
    @json_response_protocol = json_response_protocol
    super('example.com', 25565, {
      timeout: 1,
      request_type: MineStat::Request::JSON,
      srv_enabled: false,
      debug: false
    }.merge(options))
  end

  private

  def resolve_a
    true
  end

  def resolve_srv
    false
  end

  def connect
    payload = {
      'version' => { 'name' => '1.21.1', 'protocol' => @json_response_protocol },
      'players' => { 'online' => 1, 'max' => 20 },
      'description' => { 'text' => 'Hello world' }
    }
    @captured_socket = FakeJsonSocket.new(JSON.generate(payload))
    @server = @captured_socket
    MineStat::Retval::SUCCESS
  end
end

class MineStatStatusProtocolTest < Minitest::Test
  def decode_varint(data, offset = 0)
    result = 0
    shift = 0
    consumed = 0

    loop do
      byte = data.getbyte(offset + consumed)
      raise 'Invalid varint stream' if byte.nil?

      result |= (byte & 0x7F) << shift
      consumed += 1
      break if (byte & 0x80).zero?

      shift += 7
    end

    [result, consumed]
  end

  def extract_requested_protocol(handshake_packet)
    _packet_len, packet_len_size = decode_varint(handshake_packet, 0)
    packet_id = handshake_packet.getbyte(packet_len_size)
    raise "Unexpected packet id: #{packet_id}" unless packet_id == 0

    protocol, = decode_varint(handshake_packet, packet_len_size + 1)
    protocol
  end

  def test_explicit_status_protocol_is_sent_in_handshake
    ms = MineStatProtocolHarness.new({ status_protocol: 774 }, json_response_protocol: 774)

    handshake_packet = ms.captured_socket.writes[0]
    assert_equal 774, extract_requested_protocol(handshake_packet)
    assert_equal 774, ms.requested_protocol
    assert_equal 774, ms.response_protocol
    assert_equal false, ms.protocol_mismatch
  end

  def test_auto_mode_uses_default_for_auto_and_nil
    ms_auto = MineStatProtocolHarness.new({ status_protocol: :auto }, json_response_protocol: 760)
    ms_nil = MineStatProtocolHarness.new({ status_protocol: nil }, json_response_protocol: 760)

    assert_equal 760, extract_requested_protocol(ms_auto.captured_socket.writes[0])
    assert_equal 760, extract_requested_protocol(ms_nil.captured_socket.writes[0])
    assert_equal 760, ms_auto.requested_protocol
    assert_equal 760, ms_nil.requested_protocol
  end

  def test_mismatch_records_metadata_without_raising_error
    ms = MineStatProtocolHarness.new({ status_protocol: 760 }, json_response_protocol: 774)

    assert_equal true, ms.online
    assert_equal 'Success', ms.connection_status
    assert_equal 760, ms.requested_protocol
    assert_equal 774, ms.response_protocol
    assert_equal true, ms.protocol_mismatch
  end
end
