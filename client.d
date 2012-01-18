import std.stdio,std.socket,std.socketstream,std.getopt;

ushort port = 4321;
bool verbose, debugging;

int main(string[] args) {
    getopt(args,"port|p",&port,
                "verbose|v",&verbose,
                "debugging|d",&debugging);

    Socket sock = new TcpSocket;
    sock.connect(new InternetAddress("127.0.0.1",4321));
    while(sock.isAlive()) {
        auto ss = new SocketStream(sock);
        ss.writeLine("oh hai");
        auto x = new ubyte[5];
        ss.readBlock(x.ptr,x.length);
        writeln(x);
        break;
    }

    sock.close();
    return 0;
}
