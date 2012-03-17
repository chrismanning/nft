import std.stdio,
std.socket,
std.getopt,
std.algorithm,
std.string,
std.conv,
std.bitmanip,
std.path,
std.format,
std.array,
std.file
;
import util;

ushort port = 4321;
string server = "127.0.0.1";
bool verbose;
bool argUsage;

enum usage = ["pwd"  :"[loc]pwd       : Print current working directory.",
              "cd"   :"[loc]cd [dir]  : Change working directory to [dir] or back to the default if [dir] is empty.",
              "ls"   :"[loc]ls [dir]  : List [dir] entries, or current working directory if [dir] is empty.",
              "du"   :"[loc]du file   : Get size of file in bytes.",
              "mkdir":"[loc]mkdir dir : Make directory dir.",
              "rm"   :"[loc]rm name   : Remove file or empty directory called name.",
              "cptr" :"cptr file      : Upload file to server.",
              "cpfr" :"cpfr file      : Download file from server."
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
                writeln("Prefix 'loc' denotes local commands.\n'[...]' means optional.");
                foreach(string key; client.getCommands.sort) {
                    writeln(usage[key]);
                }
                continue;
            }
            auto c = Command(buf);
            if(buf.startsWith("loc")) {
                client.executeLocalCmd(c);
                continue;
            }
            if(verbose) writeln("Sending command to server...");
            try {
                client.sendMsg(c);
                if(c.cmd == "cpfr") {
                    if(!fileTransferHandler!"down"(client, c)) {
                        continue;
                    }
                }
                else if(c.cmd == "cptr") {
                    if(!fileTransferHandler!"up"(client, c)) {
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

bool fileTransferHandler(string direction)(Client client, ref Command cmd)
if(direction == "up" || direction == "down") {
    auto ds = client.receiveMsg!Reply();
    if(ds.rt == ReplyType.DATA_SETUP) {
        if(verbose) writeln("Starting data connection...");
        ubyte[2] t1 = ds.reply[0..2];
        auto port = bigEndianToNative!ushort(t1);
        ubyte[8] t2 = ds.reply[2..10];
        auto fileSize = bigEndianToNative!ulong(t2);
        client.connectDataConnection(new InternetAddress(server, port));

        try {
            static if(direction == "down") {
                if(baseName(cmd.arg).exists && getSize(baseName(cmd.arg)) == fileSize) {
                    throw new Exception("File transfer not needed");
                }
                auto f = File(baseName(cmd.arg), "wb");
                client.receiveFile(f, fileSize, true);
                return true;
            }
            else {
                client.sendMsg(Reply(nativeToBigEndian(getSize(cmd.arg)),ReplyType.DATA_SETUP));
                auto f = File(cmd.arg, "rb");
                client.sendFile(f, true);
                return true;
            }
        }
        catch(Exception e) {
            stderr.writeln(e.msg);
            client.dataSock.close();
            client.receiveMsg!Reply();
            return false;
        }
    }
    else {
        stderr.writeln(cast(string) ds.reply);
        return false;
    }
}

class Client : NFT {
    void interpretReply(Reply reply) {
        if(reply.rt == ReplyType.STRING) {
            writeln(cast(string) reply.reply);
        }
        else if(reply.rt == ReplyType.DIR_ENTRIES) {
            lsPrettyPrint(NetDirEntry.splitRawData(reply.reply));
        }
        else if(reply.rt == ReplyType.ERROR) {
            stderr.writeln(cast(string) reply.reply);
        }
        else if(reply.rt == ReplyType.DATA_SETUP) {
            //writeln(reply.reply);
        }
    }
    void executeLocalCmd(Command cmd) {
        if(cmd.cmd in localCommands) {
            localCommands[cmd.cmd](cmd.arg);
        }
        else {
            stderr.writeln("Unknown command: ", cmd.cmd);
        }
    }
}
