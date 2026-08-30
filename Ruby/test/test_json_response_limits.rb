require_relative 'test_helper'

class ScriptedJsonSocket
  attr_reader :read_calls, :recv_calls, :writes

  def initialize(read_buffer:, recv_chunks: [])
    @read_buffer = read_buffer.dup
    @recv_chunks = recv_chunks.dup
    @read_calls = []
    @recv_calls = []
    @writes = []
    @closed = false
  end

  def write(data)
    @writes << data
    data.bytesize
  end

  def flush
  end

  def close
    @closed = true
  end

  def closed?
    @closed
  end

  def read(length)
    @read_calls << length
    return nil if @read_buffer.empty?

    chunk = @read_buffer.byteslice(0, length)
    @read_buffer = @read_buffer.byteslice(length..-1) || +""
    chunk
  end

  def recv(length, _flags = nil)
    @recv_calls << length
    return nil if @recv_chunks.empty?

    chunk = @recv_chunks.shift
    return chunk if chunk.nil? || chunk.empty? || chunk.bytesize <= length

    @recv_chunks.unshift(chunk.byteslice(length..-1))
    chunk.byteslice(0, length)
  end
end

class MineStatJsonHarness < MineStat
  def initialize(socket, options = {})
    @scripted_socket = socket
    super(
      'play.example.test',
      25_565,
      {
        resolved_ip: '93.184.216.34',
        request_type: MineStat::Request::JSON,
        srv_enabled: false,
        timeout: 1
      }.merge(options)
    )
  end

  private

  def connect
    @server = @scripted_socket
    MineStat::Retval::SUCCESS
  end
end

class MineStatJsonResponseLimitsTest < Minitest::Test
  include HandshakeDecoder

  def test_payload_at_limit_is_allowed_with_bounded_chunk_reads
    payload = status_payload_with_text('x' * 20_000)
    socket = response_socket(payload, recv_chunks: [payload])

    result = MineStatJsonHarness.new(socket, max_json_bytes: payload.bytesize)

    assert_equal true, result.online
    assert_equal [16_384, payload.bytesize - 16_384], socket.recv_calls
    assert_equal true, socket.closed?
  end

  def test_limit_plus_one_is_rejected_before_payload_read
    limit = 256
    socket = declared_response_socket(json_length: limit + 1)

    result = MineStatJsonHarness.new(socket, max_json_bytes: limit)

    assert_equal false, result.online
    assert_equal 'Unknown', result.connection_status
    assert_empty socket.recv_calls
    assert_equal true, socket.closed?
  end

  def test_packet_length_mismatch_is_rejected_before_payload_read
    payload = status_payload
    socket = declared_response_socket(
      json_length: payload.bytesize,
      total_length: packet_body_length(payload.bytesize) + 1,
      recv_chunks: [payload]
    )

    result = MineStatJsonHarness.new(socket, max_json_bytes: payload.bytesize)

    assert_equal false, result.online
    assert_empty socket.recv_calls
    assert_equal true, socket.closed?
  end

  def test_partial_payload_chunks_are_accumulated_exactly
    payload = status_payload
    chunks = payload.bytes.each_slice(3).map { |bytes| bytes.pack('C*') }
    socket = response_socket(payload, recv_chunks: chunks)

    result = MineStatJsonHarness.new(socket, max_json_bytes: payload.bytesize)

    assert_equal true, result.online
    assert_operator socket.recv_calls.length, :>, 1
    assert_equal true, socket.closed?
  end

  def test_eof_during_payload_is_rejected_without_retrying_forever
    payload = status_payload
    socket = response_socket(payload, recv_chunks: [payload.byteslice(0, 5), nil])

    result = MineStatJsonHarness.new(socket, max_json_bytes: payload.bytesize)

    assert_equal false, result.online
    assert_equal 2, socket.recv_calls.length
    assert_equal true, socket.closed?
  end

  def test_zero_progress_during_payload_is_rejected_without_retrying
    payload = status_payload
    socket = response_socket(payload, recv_chunks: [''])

    result = MineStatJsonHarness.new(socket, max_json_bytes: payload.bytesize)

    assert_equal false, result.online
    assert_equal 1, socket.recv_calls.length
    assert_equal true, socket.closed?
  end

  def test_varint_requiring_a_sixth_byte_is_rejected_after_five_reads
    socket = ScriptedJsonSocket.new(read_buffer: "\x81\x81\x81\x81\x81\x00")
    instance = allocated_reader(socket)

    assert_raises(MineStat::ProtocolError) do
      instance.send(:unpack_varint, monotonic_deadline)
    end
    assert_equal 5, socket.read_calls.length
  end

  def test_five_byte_varint_is_allowed
    value = 268_435_456
    socket = ScriptedJsonSocket.new(read_buffer: pack_varint(value))
    instance = allocated_reader(socket)

    assert_equal value, instance.send(:unpack_varint, monotonic_deadline)
    assert_equal 5, socket.read_calls.length
  end

  def test_expired_deadline_stops_before_reading_payload
    socket = ScriptedJsonSocket.new(read_buffer: +"", recv_chunks: ['x'])
    instance = allocated_reader(socket)
    instance.define_singleton_method(:monotonic_now) { 2.0 }

    assert_raises(Timeout::Error) do
      instance.send(:recv_json, 1, 1.0)
    end
    assert_empty socket.recv_calls
  end

  private

  def allocated_reader(socket)
    instance = MineStat.allocate
    instance.instance_variable_set(:@server, socket)
    instance.instance_variable_set(:@timeout, 1)
    instance
  end

  def monotonic_deadline
    Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1
  end

  def response_socket(payload, recv_chunks: [payload])
    declared_response_socket(json_length: payload.bytesize, recv_chunks: recv_chunks)
  end

  def declared_response_socket(json_length:, total_length: packet_body_length(json_length), recv_chunks: [])
    header = pack_varint(total_length) << pack_varint(0) << pack_varint(json_length)
    ScriptedJsonSocket.new(read_buffer: header, recv_chunks: recv_chunks)
  end

  def packet_body_length(json_length)
    pack_varint(0).bytesize + pack_varint(json_length).bytesize + json_length
  end

  def pack_varint(value)
    buffer = +""

    loop do
      byte = value & 0x7F
      value >>= 7
      byte |= 0x80 unless value.zero?
      buffer << byte.chr
      break if value.zero?
    end

    buffer
  end

  def status_payload_with_text(text)
    JSON.generate(
      'version' => { 'name' => '1.21.1', 'protocol' => 760 },
      'players' => { 'online' => 1, 'max' => 20 },
      'description' => { 'text' => text }
    )
  end
end
