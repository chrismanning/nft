import std.stdio,
std.socket,
std.getopt,
std.algorithm,
std.string,
std.conv,
std.bitmanip,
std.path
;
import util;

ushort port = 4321;
string server = "127.0.0.1";
bool verbose;
bool argUsage;

enum usage = ["pwd"  :"pwd       : Print current (remote) working directory.",
              "cd"   :"cd [dir]  : Change (remote) working directory to [dir] or back to the default if [dir] is empty.",
              "ls"   :"ls [dir]  : List (remote) [dir] entries, or current working directory if [dir] is empty.",
              "cptr" :"cptr file : Upload file to server.",
              "cpfr" :"cpfr file : Download file from server."
             ];

static void printArgUsage() {
    writeln("-s, --server=HOST   : The remote host to use as the server (IP address or hostname).\n"
            "                    | Default is 127.0.0.1 (localhost)");
    writeln("-p, --port=PORT     : The port to connect to the server on. Default is 4321.");
    writeln("-v, --verbose       : Print some extra messages reporting progress.");
    writeln("-h, --help, --usage : Print this help page.");
}

void main(string[] args) {
    try {
        getopt(args,"server|s", &server,
                    "port|p", &port,
                    "verbose|v", &verbose,
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

    Socket control = new TcpSocket;
    if(verbose) writefln("Connecting to server: %s:%d",server,port);
    try control.connect(new InternetAddress(server,port));
    catch(SocketOSException e) {
        stderr.writeln(e.msg);
        return;
    }
    auto client = new Client;
    client.attachControlSocket(control);
    //receive welcome message
    //FIXME make a proper welcome message
    ubyte[1024] wbuf;
    auto bytes = control.receive(wbuf);
    if(bytes == Socket.ERROR) {
        return;
    }
    if(wbuf.length > int.sizeof) {
        ubyte[uint.sizeof] buf = wbuf[0..uint.sizeof];
        auto tmp = bigEndianToNative!uint(buf);
        writeln(Command(wbuf[uint.sizeof..uint.sizeof+tmp]).cmd);
    }

    string buf;
    //FIXME handle exceptions
    for(; client.status && !stdin.eof(); buf.length = 0) {
        write(" > ");
        buf = strip(stdin.readln());
        if(buf.length) {
            if(buf == "break") break;
            if(buf == "usage" || buf == "help") {
                foreach(string key; client.getCommands.sort) {
                    writeln(usage[key]);
                }
                continue;
            }
            if(verbose) writeln("Sending command to server...");
            auto c = Command(buf);
            try {
                client.sendMsg(c);
                if(buf.canFind("download")) {
                    auto ds = client.receiveMsg!Reply();
                    if(ds.rt == ReplyType.DATA_SETUP) {
                        writeln("Starting data connection");
                        ubyte[2] t1 = ds.reply[0..2];
                        auto port = bigEndianToNative!ushort(t1);
                        ubyte[8] t2 = ds.reply[2..10];
                        auto fileSize = bigEndianToNative!ulong(t2);
                        client.connectDataConnection(new InternetAddress(server, port));
                        auto f = File(baseName(c.args[0]), "wb");
                        try client.receiveFile(f, fileSize, true);
                        catch(Exception e) {
                            writeln(e.msg);
                        }
                    }
                    else {
                        stderr.writeln(cast(string) ds.reply);
                        continue;
                    }
                }

                //wait for reply
                if(verbose) writeln("Waiting for reply from server...");
                auto reply = client.receiveMsg!Reply();
                client.interpretReply(reply);
            }
            catch(DisconnectException e) {
                stderr.writeln(e.msg);
                break;
            }
            catch(NetworkErrorException e) {
                stderr.writeln(e.msg);
                break;
            }
        }
    }
    writeln("exit");
    control.close();
}

class Client : NFT {
    void interpretReply(Reply reply) {
        if(reply.rt == ReplyType.STRING) {
            writeln(cast(string) reply.reply);
        }
        else if(reply.rt == ReplyType.STRINGS) {
            writeln(to!string(reply.splitData));
        }
        else if(reply.rt == ReplyType.ERROR) {
            stderr.writeln(cast(string) reply.reply);
        }
        else if(reply.rt == ReplyType.DATA_SETUP) {
            //writeln(reply.reply);
        }
    }
}
