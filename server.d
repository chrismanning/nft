import std.socket,
std.stdio,
std.getopt,
std.conv,
std.concurrency,
std.container,
std.algorithm,
std.variant,
core.time,
core.thread
;
import util;

ushort port = 4321;
bool verbose_;
shared bool verbose;
ubyte connections = 40;
uint retries = 3;
shared run = true;

void main(string[] args) {
    getopt(args,"port|p", &port,
                "verbose|v", &verbose_,
                "connections|c", &connections,
                "retries|r", &retries
          );
    verbose = verbose_;

    auto ss = new SocketSet(connections + 1);
    Socket[] reads;
    Socket[] writes;

    auto listenerThread = spawn(&listen);

    while(!stdin.eof()) {
        getchar();
    }

    writeln("THE END...");
    send(listenerThread, true);
}

void listen() {
    Socket listener = new TcpSocket;
    //set listener non-blocking so that this thread can receive messages
    listener.blocking = false;
    //allow the server to be started instantly after being killed
    listener.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
    try listener.bind(new InternetAddress(port));
    catch(SocketOSException e) {
        stderr.writeln("ERROR: " ~ e.msg);
        stderr.writeln("A server instance may already be running.");
        listener.close();
        return;
    }
    listener.listen(10);
    auto socksTid = spawn(&socksHandler);

    auto wait = "Waiting for client to connect...";
    if(verbose) writeln(wait);
    while(true) {
        try{
            if(receiveTimeout(dur!"msecs"(100),(bool b) {})) break;
            auto sock = cast(shared)listener.accept();
            if(verbose) writeln(wait);
            send(socksTid, sock);
        }
        catch(SocketAcceptException e) {
        }
    }
    writeln("dieing");
    listener.close();
}

void socksHandler() {
    shared(Socket)[] socks;
    while(run) {
        try receive(
            (shared(Socket) sock) {
                socks ~= sock;
                spawn(&st, thisTid, sock);
                if(verbose) writeln("Adding socket. No. clients: ", socks.length);
            },
            (bool end, shared(Socket) sock) {
                foreach(i,s; socks) {
                    if(s == sock) {
                        socks = socks[0..i] ~ socks[i+1..$];
                        break;
                    }
                }
                if(verbose) writeln("Removing socket. No. clients: ", socks.length);
            },
            (Variant any) {
            }
        );
        catch(OwnerTerminated e) {
            writeln(e.msg);
        }
    }
    writeln("sock handler ending");
}

void st(Tid tid, shared(Socket) sock) {
    auto server = new Server;
    server.attachControlSocket(sock);

    if(verbose) writefln("Connection from %s established", to!string(server.remoteAddress()));
    //send welcome message
    server.control.send(cast(const(void)[]) Command("WELCOME"));
    while(server.status&& run) {// && control.isAlive()) {
        if(verbose) writeln("Waiting for command...");
        try {
            auto cmd = server.receive!Command();
            if(verbose) writefln("Command %s received",cmd.cmd);
            auto reply = server.interpreterCommand(cmd);
            if(!server.status) break;
            if(reply.length > int.sizeof+1) {
                if(verbose) writeln("Sending reply...");
                server.send(reply);
            }
        }
        catch(Exception e) {
            writeln("ERROR");
            server.status = false;
        }
    }
    server.close();
    send(tid,true,sock);
    if(verbose) writeln("Thread ending");
}

class Server : NFT {
    Reply interpreterCommand(Command c) {
        if(c.cmd == "break") {
            status = false;
            return Reply("");
        }
        auto fp = c.cmd in commands;
        if(fp) {
            auto nargs = c.args.length;
            if((*fp)(c.args)) {
                return replyBuf.back();
            }
        }
        return Reply("Unknown Command: " ~ c.cmd);
    }
}
