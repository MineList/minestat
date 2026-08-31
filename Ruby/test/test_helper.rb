require 'json'
require 'minitest/autorun'
require_relative '../lib/minestat'

class FakeJsonSocket
  attr_reader :writes

  def initialize(json_payload)
    @writes = []
    @closed = false
    @recv_buffer = json_payload.dup

    packet_id = pack_varint(0)
    json_length = pack_varint(json_payload.bytesize)
    @read_buffer = pack_varint(packet_id.bytesize + json_length.bytesize + json_payload.bytesize)
    @read_buffer << packet_id << json_length
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
end

module HandshakeDecoder
  def decode_varint(data, offset)
    value = 0
    shift = 0
    consumed = 0

    loop do
      byte = data.getbyte(offset + consumed)
      raise 'invalid VarInt' if byte.nil?

      value |= (byte & 0x7F) << shift
      consumed += 1
      break if (byte & 0x80).zero?

      shift += 7
    end

    [value, consumed]
  end

  def decode_handshake(packet)
    _packet_length, packet_length_size = decode_varint(packet, 0)
    packet_id, packet_id_size = decode_varint(packet, packet_length_size)
    protocol, protocol_size = decode_varint(packet, packet_length_size + packet_id_size)
    host_offset = packet_length_size + packet_id_size + protocol_size
    host_length, host_length_size = decode_varint(packet, host_offset)
    host_offset += host_length_size
    host = packet.byteslice(host_offset, host_length)
    port = packet.byteslice(host_offset + host_length, 2).unpack('n').first

    { packet_id: packet_id, protocol: protocol, host: host, port: port }
  end

  def status_payload
    JSON.generate(
      'version' => { 'name' => '1.21.1', 'protocol' => 760 },
      'players' => { 'online' => 1, 'max' => 20 },
      'description' => { 'text' => 'Hello world' }
    )
  end
end
