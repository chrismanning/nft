import std.socket,std.socketstream,std.stdio,std.getopt,std.conv;

ushort port = 4321;
bool verbose, debugging;

int main(string[] args) {
    getopt(args,"port|p",&port,
                "verbose|v",&verbose,
                "debugging|d",&debugging);

    Socket listener = new TcpSocket;
    listener.bind(new InternetAddress(port));
    listener.listen(10);
    //listener.blocking = false;

    while(true) {
        auto sn = listener.accept();
        writefln("Connection from %s established.", to!string(sn.remoteAddress()));
        auto ss = new SocketStream(sn);
        writeln(ss.readLine());
        ubyte[] tmp = [1,2,3,4,5];
        ss.writeBlock(tmp.ptr,tmp.length);
        break;
    }

    return 0;
}
