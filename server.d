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

void main(string[] args) {
    try {
        getopt(args,"port|p", &port,
                    "verbose|v", &verbose_,
                    "connections|c", &connections,
                    "retries|r", &retries
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

    verbose = verbose_;

    auto listenerThread = spawn(&listen, thisTid);

    while(!stdin.eof()) {
        getchar();
    }

    if(verbose) writeln("Main thread ending...");
}

shared(Socket)[] socks;
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
                (Tid thread, shared(Socket) sock) {
                    if(thread != mainThread) {
                        foreach(i,s; socks) {
                            if(s == sock) {
                                socks = socks[0..i] ~ socks[i+1..$];
                                if(verbose) writeln("Removing socket. No. clients: ", socks.length);
                                break;
                            }
                        }
                    }
                },
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
            socks ~= cast(shared) sock;
            spawn(&clientHandler, thisTid, socks[$-1]);
            if(verbose) {
                writeln("Adding socket. No. clients: ", socks.length);
                writeln(wait);
            }
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

void clientHandler(Tid sockHand, shared(Socket) sock) {
    auto server = new Server;
    server.attachControlSocket(sock);

    bool run = true;
    if(verbose) writefln("Connection from %s established", to!string(server.remoteAddress()));
    //send welcome message
    server.control.send(cast(const(void)[]) Command("WELCOME"));
    //FIXME handle exceptions
    while(server.status && run) {
        if(verbose) writeln("Waiting for command...");
        try {
            auto cmd = server.receive!Command();
            if(verbose) writefln("Command %s received",cmd.cmd);
            auto reply = server.interpreterCommand(cmd);
            if(!server.status) break;
            if(reply.length > int.sizeof+2) {
                if(verbose) writeln("Sending reply...");
                server.send(reply);
            }
        }
        catch(Exception e) {
            writeln(e.msg);
            server.status = false;
        }
    }
    server.close();
    send(sockHand, thisTid, sock);
    if(verbose) writeln("Client thread ending");
}

class Server : NFT {
    Reply interpreterCommand(Command c) {
        if(c.cmd == "break") {
            status = false;
            return Reply("", ReplyType.STRING);
        }
        auto fp = c.cmd in commands;
        if(fp) {
            auto nargs = c.args.length;
            if((*fp)(c.args)) {
                return replyBuf.back();
            }
        }
        return Reply("Unknown Command: " ~ c.cmd, ReplyType.ERROR);
    }
}
