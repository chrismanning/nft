import std.socket,std.stdio,std.getopt,std.conv;

ushort port = 4321;
bool verbose;

int main(string[] args) {
    getopt(args,"port|p",&port,
                "verbose|v",&verbose);

    Socket listener = new TcpSocket;
    listener.bind(new InternetAddress(port));
    listener.listen(10);
    //listener.blocking = false;

    while(true) {
        if(verbose) writeln("Waiting for client to connect...");
        auto control = listener.accept();
        if(verbose) writefln("Connection from %s established.", to!string(control.remoteAddress()));
        break;
    }

    return 0;
}
