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
uint retries = 3;

void main(string[] args) {
    //FIXME handle exceptions for getopt
    getopt(args,"server|s", &server,
                "port|p", &port,
                "verbose|v", &verbose,
                "retries|r", &retries
          );

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
            if(verbose) writeln("Sending command to server...");
            auto c = Command(buf);
            client.send(c);
            if(buf.canFind("download")) {
                auto ds = client.receive!Reply();
                if(ds.rt == ReplyType.DATA_SETUP) {
                    writeln("Starting data connection");
                    ubyte[2] t1 = ds.reply[0..2];
                    auto port = bigEndianToNative!ushort(t1);
                    ubyte[8] t2 = ds.reply[2..10];
                    auto fileSize = bigEndianToNative!ulong(t2);
                    client.connectDataConnection(new InternetAddress(server, port));
                    auto f = File(baseName(c.args[0]), "wb");
                    client.receiveFile(f, fileSize, true);
                }
                else {
                    stderr.writeln(cast(string) ds.reply);
                    continue;
                }
            }
            //wait for reply
            if(verbose) writeln("Waiting for reply from server...");
            auto reply = client.receive!Reply();
            client.interpretReply(reply);
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
