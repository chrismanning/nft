import std.socket,std.stdio,std.getopt,std.conv;
import util;

ushort port = 4321;
bool verbose;
ubyte connections = 40;
bool force;

void main(string[] args) {
    getopt(args,"port|p", &port,
                "verbose|v", &verbose,
                "connections|c", &connections,
                "force|f", &force
          );

    Socket listener = new TcpSocket;
    try listener.bind(new InternetAddress(port));
    catch(SocketOSException e) {
        if(!force) {
            stderr.writeln("ERROR: " ~ e.msg);
            stderr.writeln("A server instance may already be running.");
            stderr.writeln("To ignore this error, re-run with the -f or --force argument.");
            listener.close();
            return;
        }
        listener.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
    }
    listener.listen(10);
    auto ss = new SocketSet(connections + 1);
    Socket[] reads;
    Socket[] writes;

    while(true) {
        auto server = new Server;
        if(verbose) writeln("Waiting for client to connect...");
        server.attachControlSocket(listener.accept());
        if(verbose) writefln("Connection from %s established", to!string(server.remoteAddress()));
        //send welcome message
        server.control.send(cast(const(void)[]) Command("WELCOME"));
        while(server.status) {// && control.isAlive()) {
            if(verbose) writeln("Waiting for command...");
            auto cmd = server.receive!Command();
            auto reply = server.interpreterCommand(cmd);
            if(!server.status) break;
            if(reply.length > int.sizeof+1) {
                if(verbose) writeln("Sending reply...");
                server.send(reply);
            }
        }
        server.close();
    }
    listener.close();
}

class Server : NFT {
    Reply interpreterCommand(Command c) {
        if(c.cmd == "break") {
            status = false;
            return Reply("");
        }
        auto fp = c.cmd in commands;
        if(fp) {
            if(c.cmd == "ls") {
                //return Reply((*fp)(c.args.length && c.args[0].length ? c.args : [dir]));
            }
            auto nargs = c.args.length;
            if((*fp)(c.args)) {
                return replyBuf.back();
            }
        }
        return Reply("Unknown Command: " ~ c.cmd);
    }
}
