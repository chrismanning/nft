import std.stdio,std.socket,std.getopt,
        std.algorithm;

ushort port = 4321;
string server = "127.0.0.1";
bool verbose;
//enum EOF = "\u0000\u001A";

int main(string[] args) {
    getopt(args,"server|s", &server,
                "port|p",   &port,
                "verbose|v",&verbose);

    Socket control = new TcpSocket;
    try control.connect(new InternetAddress(server,4321));
    catch(SocketOSException e) {
        writeln(e.msg);
    }

    while(!stdin.eof()) {
        write(" > ");
        char[] buf;
        stdin.readln(buf);
        if(buf.length) {
        }
    }
    writeln("bye");

    control.close();
    return 0;
}

class Client {
}
