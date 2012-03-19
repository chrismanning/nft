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
bool argUsage;

static void printArgUsage() {
    writeln("-p, --port=PORT     : The port to listen on. Default is 4321.");
    writeln("-v, --verbose       : Print some extra messages reporting progress.");
    writefln("-c, --connections   : Limit the number of clients able to connect. Default is %d.", connections);
    writeln("-h, --help, --usage : Print this help page.");
}

void main(string[] args) {
    try {
        getopt(args,"port|p", &port,
                    "verbose|v", &verbose_,
                    "connections|c", &connections,
                    "usage|help|h", &argUsage
            );
    }
    catch(ConvException e) {
        stderr.writeln("Incorrect parameter: " ~ e.msg);
        return;
    }
    catch(Exception e) {
        stderr.writeln(e.msg);
        return;
    }
    if(argUsage) {
        printArgUsage();
        return;
    }

    verbose = verbose_;

    auto listenerThread = spawn(&listen, thisTid);

    while(!stdin.eof()) {
        getchar();
    }

    if(verbose) writeln("Main thread ending...");
}

shared(uint) clients;
void listen(Tid mainThread) {
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

    auto wait = "Waiting for client to connect...";
    if(verbose) writeln(wait);
    bool run = true;
    while(run) {
        try {
            receiveTimeout(dur!"msecs"(100), //this blocks--stopping accept from using too many cycles
                (OwnerTerminated e) {
                    //stop doing stuff when main thread ends
                    run = false;
                    listener.close();
                },
                (Variant any) {
                    //this stops the message buffer from filling up
                }
            );
            auto sock = listener.accept();
            version(Windows) sock.blocking = true;
            spawn(&clientHandler, thisTid, cast(shared) sock);
            if(verbose) writeln(wait);
        }
        catch(SocketOSException e) {
            /* Non-blocking accept() throws a SocketAcceptException on failure to connect
             * (ie. when waiting).
             * On windows accept() doesn't throw but any other operation (like set it to
             * block) will as the socket isn't connected.
             * This is expected so let the loop continue.
             */
        }
    }
    listener.close();
    if(verbose) writeln("Listener thread ending...");
}

void clientHandler(Tid listenThread, shared(Socket) sock) {
    clients++;
    if(verbose) writeln("Adding client. No. clients: ", clients);
    auto server = new Server;
    server.attachControlSocket(sock);

    bool run = true;
    if(verbose) writefln("Connection from %s established", to!string(server.remoteAddress()));
    //send welcome message
    server.control.send(cast(ubyte[]) ID ~ cast(const(void)[]) Command("WELCOME"));
    while(server.status && run) {
        if(verbose) writeln("Waiting for command...");
        try {
            auto cmd = server.receiveMsg!Command();
            if(verbose) writefln("Command %s received",cmd.cmd);
            auto reply = server.interpreterCommand(cmd);
            if(!server.status) break;
            if(reply.length > int.sizeof+2) {
                if(verbose) writeln("Sending reply...");
                server.sendMsg(reply);
            }
        }
        catch(Exception e) {
            writeln(e.msg);
            server.status = false;
            break;
        }
    }
    server.close();
    send(listenThread, thisTid);
    if(verbose) writeln("Client thread ending");
    clients--;
    writeln("Removing client. No. clients: ", clients);
}

class Server : NFT {
    Reply interpreterCommand(Command c) {
        if(c.cmd == "break") {
            status = false;
            return Reply("", ReplyType.STRING);
        }
        auto fp = c.cmd in commands;
        if(fp) {
            if((*fp)(c.arg)) {
                return replyBuf.back();
            }
        }
        return Reply("Unknown Command: " ~ c.cmd, ReplyType.ERROR);
    }
}
