require_relative 'test_helper'
require 'openssl'

class MineStatNetherNetTest < Minitest::Test
  HOST = 'signaling.example.test'

  def setup
    skip 'NetherNet requires Ruby 2.7+' unless Net::HTTP.method_defined?(:ipaddr=)
    @requests = Queue.new
    @sni = Queue.new
  end

  def metadata
    { 'name' => '§a테스트 server', 'protocol' => 2177, 'version' => '1.26.50',
      'level' => 'World', 'players' => 0, 'maxPlayers' => 10, 'gameType' => 0 }
  end

  def response(body = JSON.generate(metadata), status: 200, headers: {})
    headers = { 'Content-Type' => 'application/json', 'Content-Length' => body.bytesize,
                'Connection' => 'close' }.merge(headers)
    "HTTP/1.1 #{status} Test\r\n" + headers.map { |k, v| "#{k}: #{v}\r\n" }.join + "\r\n" + body
  end

  # Real loopback HTTP/TLS server; no external DNS, CA or service dependency.
  def with_server(reply = response, tls: false, certificate_host: HOST, trust: true, bind: '127.0.0.1', &block)
    tcp = TCPServer.new(bind, 0)
    port = tcp.addr[1]
    context = nil
    if tls
      key = OpenSSL::PKey::RSA.new(2048)
      cert = OpenSSL::X509::Certificate.new
      cert.version = 2
      cert.serial = 1
      cert.subject = cert.issuer = OpenSSL::X509::Name.parse("/CN=#{certificate_host}")
      cert.public_key = key.public_key
      cert.not_before = Time.now - 60
      cert.not_after = Time.now + 3600
      factory = OpenSSL::X509::ExtensionFactory.new
      factory.subject_certificate = factory.issuer_certificate = cert
      cert.add_extension(factory.create_extension('subjectAltName', "DNS:#{certificate_host}"))
      cert.sign(key, OpenSSL::Digest.new('SHA256'))
      context = OpenSSL::SSL::SSLContext.new
      context.cert = cert
      context.key = key
      context.servername_cb = proc { |_socket, name| @sni << name; nil }
      store = OpenSSL::X509::Store.new
      store.add_cert(cert) if trust
    end
    worker = Thread.new do
      client = nil
      begin
        client = tcp.accept
        if context
          client = OpenSSL::SSL::SSLSocket.new(client, context)
          client.sync_close = true
          client.accept
        end
        request = +''
        while (line = client.gets)
          request << line
          break if line == "\r\n"
        end
        @requests << request
        reply.respond_to?(:call) ? reply.call(client) : client.write(reply)
      rescue OpenSSL::SSL::SSLError, Errno::EPIPE, Errno::ECONNRESET, IOError
        # Expected when the client rejects TLS or abandons an invalid response.
      ensure
        client.close if client && !client.closed?
      end
    end
    if tls
      original = Net::HTTP.method(:new)
      Net::HTTP.stub(:new, lambda { |*args|
        http = original.call(*args)
        http.cert_store = store
        http
      }) { block.call(port) }
    else
      block.call(port)
    end
  ensure
    tcp.close if tcp && !tcp.closed?
    if worker
      worker.join(1)
      worker.kill if worker.alive?
      worker.join
    end
  end

  def query(port, options = {})
    Resolv.stub(:getaddress, lambda { |*| flunk 'pinned request must not resolve DNS' }) do
      Resolv::DNS.stub(:new, lambda { |*| flunk 'NetherNet must not look up SRV or A records' }) do
        MineStat.new(HOST, port, { request_type: MineStat::Request::NETHERNET,
          resolved_ip: '127.0.0.1', timeout: 1, nethernet_scheme: 'http' }.merge(options))
      end
    end
  end

  def assert_offline(result, status)
    refute result.online
    assert_equal status, result.connection_status
    assert_nil result.motd
    assert_nil result.json_data
  end

  def test_maps_metadata_and_preserves_host_with_pinned_connection
    with_server do |port|
      result = query(port)
      assert result.online
      assert_equal 'Success', result.connection_status
      assert_equal metadata, result.json_data
      assert_equal metadata['name'], result.motd
      assert_equal '테스트 server', result.stripped_motd
      assert_equal 2177, result.protocol
      assert_equal '1.26.50', result.version
      assert_equal 'World', result.level
      assert_equal 0, result.current_players
      assert_equal 10, result.max_players
      assert_equal 'Survival', result.mode
      assert_equal 'Bedrock NetherNet', result.request_type
      assert_equal '127.0.0.1', result.resolved_ip
      refute result.srv_enabled
      refute result.try_all
      assert_operator result.latency, :>=, 0
      request = @requests.pop(true)
      assert_match %r{\AGET /v1/join HTTP/1.1\r\n}, request
      assert_includes request, "Host: #{HOST}:#{port}\r\n"
      assert_includes request, "Accept-Encoding: identity\r\n"
    end
  end

  def test_https_uses_original_host_for_sni_and_certificate_verification
    with_server(tls: true) do |port|
      assert query(port, nethernet_scheme: 'https').online
      assert_equal HOST, @sni.pop(true)
      assert_includes @requests.pop(true), "Host: #{HOST}:#{port}\r\n"
    end
  end

  def test_https_rejects_trusted_certificate_for_wrong_hostname
    with_server(tls: true, certificate_host: 'wrong.example.test') do |port|
      assert_offline query(port, nethernet_scheme: 'https'), 'Fail'
      assert_equal HOST, @sni.pop(true)
      assert @requests.empty?
    end
  end

  def test_https_rejects_untrusted_certificate
    with_server(tls: true, trust: false) do |port|
      assert_offline query(port, nethernet_scheme: 'https'), 'Fail'
      assert @requests.empty?
    end
  end

  def test_modes_numeric_numbers_and_extension_fields
    { 1 => 'Creative', 2 => 'Adventure', 99 => 'Unknown (99)' }.each do |id, mode|
      data = metadata.merge('gameType' => id, 'players' => 2.0, 'extension' => true)
      with_server(response(JSON.generate(data))) do |port|
        result = query(port)
        assert result.online
        assert_equal mode, result.mode
        assert_equal 2, result.current_players
        assert_equal true, result.json_data['extension']
      end
    end
  end

  def test_rejects_missing_and_invalid_fields_without_partial_results
    invalid = [nil, [], {}, 'text', metadata.merge('name' => nil),
      metadata.merge('players' => '1'), metadata.merge('protocol' => true),
      metadata.merge('maxPlayers' => -1), metadata.merge('gameType' => 0.5),
      metadata.merge('level' => []), metadata.merge('version' => 1)]
    metadata.each_key { |key| invalid << metadata.reject { |k, _| k == key } }
    invalid.each do |data|
      with_server(response(JSON.generate(data))) { |port| assert_offline query(port), 'Unknown' }
    end
    ['{', '', '{"players": NaN}', "\xff".b].each do |body|
      with_server(response(body)) { |port| assert_offline query(port), 'Unknown' }
    end
  end

  def test_accepts_other_success_codes_but_rejects_empty_success
    with_server(response(status: 201)) { |port| assert query(port).online }
    with_server(response('', status: 204)) { |port| assert_offline query(port), 'Unknown' }
  end

  def test_non_success_and_redirects_do_not_follow_location
    [301, 302, 307, 308, 400, 404, 429, 500].each do |status|
      with_server(response(status: status, headers: { 'Location' => 'http://other.example.test/v1/join' })) do |port|
        assert_offline query(port), 'Unknown'
        assert_equal 1, @requests.size
        @requests.pop(true)
      end
    end
  end

  def test_rejects_wrong_content_type_encoding_and_truncated_body
    [{ 'Content-Type' => 'text/html' }, { 'Content-Encoding' => 'gzip' },
     { 'Content-Length' => 1000 }].each do |headers|
      with_server(response(headers: headers)) { |port| assert_offline query(port), 'Unknown' }
    end
  end

  def test_bounds_fixed_length_and_chunked_responses
    limit = MineStat::NETHERNET_MAX_RESPONSE_BYTES
    padded = JSON.generate(metadata)
    padded += ' ' * (limit - padded.bytesize)
    with_server(response(padded)) { |port| assert query(port).online }
    with_server(response(padded + ' ')) { |port| assert_offline query(port), 'Unknown' }
    chunked = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n"
    chunked += "#{(limit + 1).to_s(16)}\r\n#{' ' * (limit + 1)}\r\n0\r\n\r\n"
    with_server(chunked) { |port| assert_offline query(port), 'Unknown' }
  end

  def test_rejects_oversized_http_framing_before_accepting_metadata
    oversized = 'a' * (2 * 1024 * 1024)
    body = JSON.generate(metadata)
    chunked_headers = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n"
    replies = [
      response(headers: { 'X-Padding' => oversized }),
      "HTTP/1.1 200 #{oversized}\r\n\r\n",
      "HTTP/1.1 200 OK\r\n" + ("X-Padding: #{'a' * 1024}\r\n" * 2048) + "\r\n",
      chunked_headers + "#{body.bytesize.to_s(16)};padding=#{oversized}\r\n#{body}\r\n0\r\n\r\n",
      chunked_headers + "#{body.bytesize.to_s(16)}\r\n#{body}\r\n0\r\nX-Trailer: #{oversized}\r\n\r\n"
    ]
    replies.each do |reply|
      with_server(reply) { |port| assert_offline query(port), 'Unknown' }
    end
  end

  def test_rejects_unsafe_loaded_http_version_before_dns_or_connection
    original_version = Net::HTTP::VERSION
    ['0.6.0', '0.9.1', '0.10.0.pre'].each do |version|
      Net::HTTP.send(:remove_const, :VERSION)
      Net::HTTP.const_set(:VERSION, version)
      Net::HTTP.stub(:new, lambda { |*| flunk 'unsafe parser must not connect' }) do
        Resolv.stub(:getaddress, lambda { |*| flunk 'unsafe parser must not resolve DNS' }) do
          error = assert_raises(ArgumentError) do
            MineStat.new(HOST, 443, request_type: MineStat::Request::NETHERNET)
          end
          assert_includes error.message, 'net-http >= 0.10.0'
        end
      end
    end
  ensure
    Net::HTTP.send(:remove_const, :VERSION)
    Net::HTTP.const_set(:VERSION, original_version)
  end

  def test_read_and_tls_handshake_timeouts
    stall = lambda { |_client| sleep 0.3 }
    with_server(stall) { |port| assert_offline query(port, timeout: 0.05), 'Timeout' }
    with_server(stall) do |port|
      assert_offline query(port, timeout: 0.05, nethernet_scheme: 'https'), 'Timeout'
    end
  end

  def test_total_deadline_limits_slow_stream
    drip = lambda do |client|
      client.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 1000\r\n\r\n")
      30.times { client.write(' '); sleep 0.02 }
    end
    with_server(drip) do |port|
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      assert_offline query(port, timeout: 0.12), 'Timeout'
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 0.5
    end
  end

  def test_refused_connection_is_fail_without_dns_fallback
    socket = TCPServer.new('127.0.0.1', 0)
    port = socket.addr[1]
    socket.close
    assert_offline query(port), 'Fail'
  end

  def test_ipv6_pin_preserves_original_host
    with_server(bind: '::1') do |port|
      result = query(port, resolved_ip: '::1')
      assert result.online
      assert_equal '::1', result.resolved_ip
      assert_includes @requests.pop(true), "Host: #{HOST}:#{port}\r\n"
    end
  end

  def test_ipv6_literal_host_is_bracketed_in_http_header
    with_server(bind: '::1') do |port|
      result = MineStat.new('::1', port, request_type: MineStat::Request::NETHERNET,
        resolved_ip: '::1', nethernet_scheme: 'http', timeout: 1)
      assert result.online
      assert_includes @requests.pop(true), "Host: [::1]:#{port}\r\n"
    end
  end

  def test_open_timeout_and_network_error_statuses
    original = Net::HTTP.method(:new)
    { Net::OpenTimeout => 'Timeout', Errno::ECONNRESET => 'Fail' }.each do |error, status|
      Net::HTTP.stub(:new, lambda { |*args|
        http = original.call(*args)
        http.define_singleton_method(:start) { raise error }
        http
      }) do
        assert_offline query(443, nethernet_scheme: 'https'), status
      end
    end
  end

  def test_no_retry_on_eof
    with_server('') do |port|
      assert_offline query(port, timeout: 0.1), 'Unknown'
      assert_equal 1, @requests.size
    end
  end

  def test_invalid_http_status_is_unknown
    with_server("not HTTP\r\n\r\n") { |port| assert_offline query(port), 'Unknown' }
  end

  def test_proxy_environment_cannot_override_pin
    original = ENV['http_proxy']
    ENV['http_proxy'] = 'http://unresolvable-proxy.example.test:1234'
    with_server { |port| assert query(port).online }
  ensure
    ENV['http_proxy'] = original
  end

  def test_unpinned_request_resolves_once_and_never_uses_srv
    with_server do |port|
      calls = []
      Resolv.stub(:getaddress, lambda { |host| calls << host; '127.0.0.1' }) do
        Resolv::DNS.stub(:new, lambda { |*| flunk 'no SRV query expected' }) do
          result = MineStat.new(HOST, port, request_type: MineStat::Request::NETHERNET,
            nethernet_scheme: 'http', timeout: 1)
          assert result.online
          assert_equal '127.0.0.1', result.resolved_ip
        end
      end
      assert_equal [HOST], calls
    end
  end

  def test_dns_failure_and_timeout
    [Resolv::ResolvError, Timeout::Error].zip(%w[Fail Timeout]).each do |error, status|
      Resolv.stub(:getaddress, lambda { |*| raise error }) do
        result = MineStat.new(HOST, nil, request_type: MineStat::Request::NETHERNET)
        assert_offline result, status
      end
    end
  end

  def test_total_deadline_includes_dns_resolution
    Resolv.stub(:getaddress, lambda { |*| sleep 0.3; '127.0.0.1' }) do
      result = MineStat.new(HOST, 443, request_type: MineStat::Request::NETHERNET, timeout: 0.05)
      assert_offline result, 'Timeout'
    end
  end

  def test_automatic_protocol_sequence_does_not_include_nethernet
    harness = Class.new(MineStat) do
      [:legacy_request, :beta_request, :extended_legacy_request, :json_request,
       :bedrock_request, :query_request].each do |method|
        define_method(method) { MineStat::Retval::UNKNOWN }
      end
      def nethernet_request
        raise 'automatic sequence must not attempt NetherNet'
      end
    end
    result = harness.new('127.0.0.1', 25_565, srv_enabled: false,
      request_type: MineStat::Request::NONE)
    assert_offline result, 'Unknown'
    assert result.try_all
  end

  def test_defaults_and_argument_validation
    harness = Class.new(MineStat) do
      def nethernet_request
        MineStat::Retval::UNKNOWN
      end
    end
    options = { request_type: MineStat::Request::NETHERNET }
    result = harness.new(HOST, nil, options)
    assert_equal 443, result.port
    assert_equal 5, result.timeout
    assert_equal 'https', result.instance_variable_get(:@nethernet_scheme)
    assert_equal 80, harness.new(HOST, nil, options.merge(nethernet_scheme: 'http')).port
    [0, -1, Float::INFINITY, Float::NAN, '1', nil].each do |timeout|
      assert_raises(ArgumentError) { harness.new(HOST, 443, options.merge(timeout: timeout)) }
    end
    [0, 65536, '443'].each do |port|
      assert_raises(ArgumentError) { harness.new(HOST, port, options) }
    end
    [nil, 'ftp', :http].each do |scheme|
      assert_raises(ArgumentError) { harness.new(HOST, 443, options.merge(nethernet_scheme: scheme)) }
    end
    ['https://example.test', "host\r\nInjected: x", 'user@host', 'host/path', 'host:443', ''].each do |host|
      assert_raises(ArgumentError) { harness.new(host, 443, options) }
    end
  end
end
