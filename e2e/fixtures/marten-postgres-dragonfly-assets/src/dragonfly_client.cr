require "socket"

class DragonflyClient
  def initialize(@endpoint : String)
  end

  def set(key : String, value : String) : Nil
    command("SET", key, value)
  end

  def get(key : String) : String
    command("GET", key)
  end

  private def command(*parts : String) : String
    host, port = parse_endpoint

    TCPSocket.open(host, port) do |socket|
      socket << "*#{parts.size}\r\n"
      parts.each do |part|
        socket << "$#{part.bytesize}\r\n#{part}\r\n"
      end
      socket.flush
      read_response(socket)
    end
  end

  private def read_response(socket : TCPSocket) : String
    line = socket.gets || ""
    return line.lchop("+").strip if line.starts_with?("+")
    return "" unless line.starts_with?("$")

    size = line.lchop("$").to_i
    return "" if size < 0

    value = Bytes.new(size)
    socket.read_fully(value)
    socket.read_byte
    socket.read_byte
    String.new(value)
  end

  private def parse_endpoint : Tuple(String, Int32)
    host, port = @endpoint.split(":", 2)
    {host, port.to_i}
  end
end
