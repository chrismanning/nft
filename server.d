import std.socket,std.stdio,std.getopt,std.conv;
import util;

ushort port = 4321;
bool verbose;
ubyte connections = 40;

void main(string[] args) {
    getopt(args,"port|p",&port,
                "verbose|v",&verbose,
                "connections|c",&connections);

    Socket listener = new TcpSocket;
    listener.bind(new InternetAddress(port));
    listener.listen(10);
    auto ss = new SocketSet(connections + 1);
    Socket[] reads;
    Socket[] writes;

    auto server = new Server;
    if(verbose) writeln("Waiting for client to connect...");
    auto control = listener.accept();
    if(verbose) writefln("Connection from %s established", to!string(control.remoteAddress()));
    //send welcome message
    control.send(cast(const(void)[]) Command("WELCOME"));
    while(server.status && control.isAlive()) {
        ubyte[1024] buf;
        //wait for command
        if(verbose) writeln("Waiting for command...");
        auto bytes = control.receive(buf);
        if(bytes == Socket.ERROR) {
            writeln("Error!");
            break;
        }
        else if(bytes == 0) break;
        else if(bytes > int.sizeof) {
            auto size = (cast(int[])buf)[0];
            auto tmp = buf[int.sizeof..int.sizeof+size];
            if(tmp[0] == MsgType.CMD) {
                auto reply = server.interpreterCommand(Command(tmp));
                if(!server.status) break;
                if(reply.length > int.sizeof) {
                    bytes = control.send(cast(const(void)[]) reply);
                    if(bytes == reply.length) {
                        if(verbose) writeln("Successfully replied.");
                    }
                }
            }
        }
    }
    control.shutdown(SocketShutdown.BOTH);
    control.close();
    listener.close();
}

class Server {
    string pwd;
    bool status;
    this() {
        pwd = ".";
        status = true;
    }
    Reply interpreterCommand(Command c) {
        writeln(c.cmd);
        if(c.cmd == "break") {
            status = false;
        }
        auto fp = c.cmd in commands;
        if(fp) {
            return Reply((*fp)(c.args));
        }
        return Reply("Unknown Command");
    }
}
