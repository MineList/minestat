require_relative 'lib/minestat'

# Example demonstrating the new exception handling feature
puts "=== MineStat Exception Handling Example ==="
puts ""

# Example 1: Query with proper parameters (notice we need both address and port)
puts "Example 1: Querying an unreachable server"
ms = MineStat.new("nonexistent-server.example.com", 25565, timeout: 2, debug: false)
puts "  Server online: #{ms.online}"
puts "  Connection status: #{ms.connection_status}"

# NEW FEATURE: Access exception details programmatically
if ms.exception
  puts "  Exception available for debugging:"
  puts "    - Type: #{ms.exception.class}"
  puts "    - Message: #{ms.exception.message}"
end
puts ""

# Example 2: With debug mode enabled
puts "Example 2: Same query with debug mode enabled"
puts "  (Notice the stderr output below)"
ms2 = MineStat.new("another-unreachable.example.com", 25565, timeout: 2, debug: true)
puts "  Server online: #{ms2.online}"
puts "  Connection status: #{ms2.connection_status}"
if ms2.exception
  puts "  Exception is ALSO available via @exception variable:"
  puts "    - Type: #{ms2.exception.class}"
  puts "    - Message: #{ms2.exception.message}"
end
puts ""

puts "=== Summary ==="
puts "The @exception variable provides programmatic access to error details,"
puts "making debugging easier without requiring stderr parsing."
