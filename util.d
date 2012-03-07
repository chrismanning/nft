module util;

import std.file,
std.stdio,
std.string,
std.array,
std.algorithm,
std.conv,
std.path,
std.exception,
std.container,
std.socket,
std.traits,
std.concurrency,
core.thread,
std.bitmanip,
std.outbuffer,
std.regex
;

enum MsgType : ubyte {
    CMD,
    REPLY,
    DATA,
}

enum ReplyType : ubyte {
    STRING,
    STRINGS,
    ERROR,
    DATA_SETUP
}

enum BUFSIZE = 8 * 1024;

template isMsgType(T) {
    enum isMsgType = is(T == Command) || is(T == Reply);
}

abstract class NFT {
public:
    this() {
        commands["ls"] = &ls;
        commands["pwd"] = &pwd;
        commands["cd"] = &cd;
        commands["download"] = &download;
        commands["upload"] = &upload;
        dir = getcwd();
        status = true;
    }

    void attachControlSocket(Socket sock) {
        control = sock;
    }
    void attachControlSocket(shared(Socket) sock) {
        control = cast(Socket)sock;
    }

    void close() {
        control.shutdown(SocketShutdown.BOTH);
        control.close();
    }

    void success(Msg)() if(isMsgType!Msg) {
        static if(is(Msg == Reply)) {
            if(replyBuf.length)
                replyBuf.removeBack();
        }
        else static if(is(Msg == Command)) {
            if(cmdBuf.length)
                cmdBuf.removeBack();
        }
    }

    void connectDataConnection(Address remote) {
        dataSock = new TcpSocket;

        try {
            dataSock.connect(remote);
        }
        catch(SocketOSException e) {
            stderr.writeln(e.msg);
        }
    }

    void sendFile(ref File file) {
        if(dataSock.isAlive()) {
            ulong bytesSent;
            foreach(ubyte[] buf; file.byChunk(BUFSIZE)) {
                auto bytes = dataSock.send(buf);
                if(bytes == buf.length) {
                    bytesSent += bytes;
                    if(bytes < BUFSIZE && bytesSent < file.size()) {
                        throw new Exception("Unexpected end of buffer");
                    }
                }
                else if(bytes == 0)
                    throw new Exception("Client has disconnected");
                else if(bytes == Socket.ERROR)
                    throw new Exception("Network Error");
                else
                    throw new Exception("Wrong amount of data sent");
            }
        }
    }

    void receiveFile(ref File file, ulong size) {
        if(dataSock.isAlive()) {
            ulong bytesReceived;
            while(bytesReceived < size) {
                ubyte[BUFSIZE] buf;
                auto bytes = dataSock.receive(buf);
                if(bytes > 0) {
                    bytesReceived += bytes;
                    if(bytes < BUFSIZE && bytesReceived < size) {
                        throw new Exception("Unexpected end of buffer");
                    }
                    file.rawWrite(buf[0..bytes]);
                }
                else if(bytes == 0)
                    throw new Exception("Client has disconnected");
                else if(bytes == Socket.ERROR)
                    throw new Exception("Network Error");
                else
                    throw new Exception("Wrong amount of data sent");

            }
            writeln("File size: ", size);
            writeln("Actual size: ", file.size());
        }
    }

    void send(Msg)(Msg msg) if(isMsgType!Msg) {
        auto bytes = control.send(cast(const(void)[]) msg);
        if(bytes == msg.length) {
            success!Msg();
            return;
        }
        else if(bytes == 0)
            throw new Exception("Client has disconnected");
        else if(bytes == Socket.ERROR)
            throw new Exception("Network Error");
        else
            throw new Exception("Wrong amount of data sent");
    }

    Msg receive(Msg)() if(isMsgType!Msg) {
        //first 5 bytes should be size of data (4 bytes) + msg type (1 byte)
        ubyte[5] buf;
        auto bytes = control.receive(buf);

        if(bytes == buf.length) {
            static if(is(Msg == Command)) {
                if(buf[int.sizeof] != MsgType.CMD) throw new Exception("Wrong message type");
            }
            else {
                if(buf[int.sizeof] != MsgType.REPLY) throw new Exception("Wrong message type");
            }
            ubyte[uint.sizeof] t1 = buf[0..uint.sizeof];
            uint msgSize = bigEndianToNative!uint(t1);
            auto buffer = new ubyte[msgSize-uint.sizeof-1]; //dynamic array of rest
            bytes = control.receive(buffer);

            if(bytes == msgSize-int.sizeof-1) {
                return Msg(buf[int.sizeof] ~ buffer);
            }
        }
        if(bytes == 0) {
            throw new Exception("Remote host has disconnected");
        }
        else if(bytes == Socket.ERROR) {
            throw new Exception("Network Error");
        }
        else
            throw new Exception("Wrong amount of data received");
    }

    auto remoteAddress() {
        return control.remoteAddress();
    }

    bool status;

protected:
    Array!Command cmdBuf;
    Array!Reply replyBuf;
    alias bool delegate(string[] args ...) cmd;
    cmd[string] commands;
    Socket control;
    Socket dataSock;

private:
    bool ls(string[] args ...) {
        auto x = replyBuf.length;
        if(args.length) {
//            foreach(arg; args) {
//                //FIXME handle argument for ls
//            }
        }
        string tmp;
        foreach(string name; dirEntries(dir, SpanMode.shallow)) {
            tmp ~= relativePath(name, dir) ~ 0;
        }
        replyBuf.insertBack(Reply(tmp[0..$-1].idup, ReplyType.STRINGS));
        return replyBuf.length == x+1;
    }

    bool pwd(string[] args ...) {
        auto x = replyBuf.length;
        replyBuf.insertBack(Reply(absolutePath(dir), ReplyType.STRING));
        return replyBuf.length == x+1;
    }

    bool cd(string[] args ...) {
        auto x = replyBuf.length;
        if(args.length) {
            auto str = buildNormalizedPath(absolutePath(args[0], dir));
            if(str.isDir) {
                dir = str;
                replyBuf.insertBack(Reply(str, ReplyType.STRING));
            }
            else
                replyBuf.insertBack(Reply(absolutePath(dir), ReplyType.STRING));
        }
        else {
            dir = getcwd();
            replyBuf.insertBack(Reply(dir, ReplyType.STRING));
        }
        return replyBuf.length == x+1;
    }

    Socket openDataConnection() {
        Socket s = new TcpSocket;
        s.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
        s.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, dur!"seconds"(3));

        try s.bind(new InternetAddress(InternetAddress.PORT_ANY));
        catch(SocketOSException e) {
            s.close();
            throw e;
        }

        s.listen(1);

        return s;
    }

    bool download(string[] args ...) {
        auto x = replyBuf.length;
        Reply * reply;
        if(args.length) {
            auto filename = absolutePath(args[0], dir);
            if(filename.exists() && filename.isFile()) {
                try {
                    auto sock = this.openDataConnection();
                    auto p = sock.localAddress().toPortString();
                    auto port = parse!ushort(p);
                    auto f = File(filename,"rb");
                    auto rb = nativeToBigEndian(port) ~ nativeToBigEndian(f.size());
                    reply = new Reply(rb, ReplyType.DATA_SETUP);
                    this.send(*reply);
                    dataSock = sock.accept();
                    sendFile(f);
                }
                catch(Exception e) {
                    reply = new Reply(e.msg, ReplyType.ERROR);
                }
                finally {
                    if(reply) {
                        replyBuf.insertBack(*reply);
                    }
                }
            }
            else {
                replyBuf.insertBack(Reply(args[0] ~ ": No such file", ReplyType.ERROR));
            }
        }
        else {
            replyBuf.insertBack(Reply("Need an argument", ReplyType.ERROR));
        }
        return replyBuf.length == x+1;
    }

    bool upload(string[] args ...) {
        auto x = replyBuf.length;
        return replyBuf.length == x+1;
    }

    string dir;
}

struct Command {
    this(string input) {
        //separate the command and arguments with regex
        //also accepts quoted strings for arguments
        auto argPattern = regex(`[^\s"']+|"([^"]*)"|'([^']*)'`, "g");
        auto tmp = match(strip(input), argPattern);
        if(tmp) {
            cmd = tmp.front.hit;
            tmp.popFront();
            foreach(capture; tmp) {
                if(capture.hit.startsWith(`"`)) {
                    writeln("quoted");
                    writeln(capture);
                    capture.popFront();
                    writeln(capture);
                }
                if(capture.hit.length) {
                    args ~= capture.front;
                }
            }
        }
        else cmd = strip(input);
    }
    this(ubyte[] input) {
        //if taking the raw input it should at least be the right type
        enforce(input[0] == MsgType.CMD,"Not a CMD");
        auto tmp = array(filter!(a => a.length > 0)(std.algorithm.splitter(input[1..$],cast(ubyte)0)));
        if(tmp.length) {
            cmd = cast(string) tmp[0];
            if(tmp.length > 1) {
                args = cast(string[]) tmp[1..$];
            }
        }
        else cmd = strip(cast(string)input);
    }

    @property uint length() {
        return cast(uint) (uint.sizeof + 1 + cmd.length + 1 + reduce!("a + b.length")(0L,args) + args.length);
    }

    const(void)[] opCast() {
        auto buf = new OutBuffer;
        buf.reserve(length);

        buf.write(nativeToBigEndian(length).dup);
        buf.write(cast(ubyte) MsgType.CMD);
        buf.write(cmd);
        buf.write(new ubyte[1]);
        foreach(arg; args) {
            buf.write(arg);
            buf.write(new ubyte[1]);
        }
        return buf.toBytes();
    }

    string cmd;
    string[] args;
}

struct Reply {
    this(ubyte[] input) {
        enforce(input[0] == MsgType.REPLY,"Not a REPLY");
        rt = input[1];
        reply = input[2..$];
    }
    this(ubyte[] input, ubyte rt_) {
        rt = rt_;
        reply = input;
    }
    this(string input, ubyte rt_ = ReplyType.STRING) {
        rt = rt_;
        reply = cast(ubyte[])input;
    }
    this(string[] input, ubyte rt_ = ReplyType.STRINGS) {
        rt = rt_;
        foreach(str; input) {
            reply ~= cast(ubyte[]) str ~ 0;
        }
        reply = reply[0..$-1];
    }

    //copy constructor
    this(this) {
        reply = reply.dup;
    }

    @property uint length() {
        return cast(uint)(uint.sizeof + reply.length + 2);
    }

    const(void)[] opCast() {
        auto buf = new OutBuffer;
        buf.reserve(length);

        buf.write(nativeToBigEndian(length).dup);
        buf.write(cast(ubyte) MsgType.REPLY);
        buf.write(rt);
        buf.write(reply);

        return buf.toBytes();
    }

    string[] splitData() {
        return cast(string[]) array(filter!(a => a.length > 0)(std.algorithm.splitter(reply,cast(ubyte)0)));
    }

    ubyte rt;
    ubyte[] reply;
}
