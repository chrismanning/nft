import std.socket,std.stdio,std.getopt,std.conv;

ushort port = 4321;
bool verbose, debugging;

int main(string[] args) {
    getopt(args,"port|p",&port,
                "verbose|v",&verbose,
                "debugging|d",&debugging);

    Socket listener = new TcpSocket;
    listener.bind(new InternetAddress(port));
    listener.listen(10);

    while(true) {
        auto sn = listener.accept();
        writefln("Connection from %s established.", to!string(sn.remoteAddress()));
        sn.close();
        break;
    }

    return 0;
}