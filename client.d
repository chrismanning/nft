import std.socket;

int main(string[] args) {
    Socket sock = new TcpSocket;
    sock.connect(new InternetAddress("127.0.0.1",4321));
    while(sock.isAlive()) {
        break;
    }
    sock.close();
    return 0;
}