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
std.typecons,
std.socket,
std.traits,
core.thread,
std.bitmanip,
std.outbuffer,
std.regex,
std.datetime,
std.format
;
version(Posix) import
core.stdc.config
;

enum MsgType : ubyte {
    CMD,
    REPLY,
    DATA,
}

enum ReplyType : ubyte {
    STRING,
    DIR_ENTRIES,
    ERROR,
    DATA_SETUP
}

class DisconnectException : Exception {
    this(Address raddr) {
        super(raddr.toString ~ " disconnected");
    }
    this(Socket rsock) {
        super(rsock.remoteAddress.toString ~ " disconnected");
        rsock.close();
    }
}

class NetworkErrorException : Exception {
    this() {
        super("A network error occurred");
    }
}

class WrongMsgException : Exception {
    this(TypeInfo exp, TypeInfo got) {
        super("Expected " ~ to!string(exp) ~
              ", got " ~ to!string(got));
    }
}

enum BUFSIZE = 8 * 1024;

template isMsgType(T) {
    enum isMsgType = is(T == Command) || is(T == Reply);
}

struct NetDirEntry {
    this(DirEntry e) {
        name = e.name;
        isDir = e.isDir;
        attributes = e.attributes;
    }
    this(ubyte[] raw) {
        isDir = cast(bool)raw[0];
        ubyte[uint.sizeof] tmp = raw[1..5];
        attributes = bigEndianToNative!uint(tmp);
        name = cast(string) raw[5..$];
    }
    string name;
    bool isDir;
    uint attributes;
    @property uint length() const {
        return cast(uint) name.length + 5;
    }
    ubyte[] opCast() immutable {
        auto buf = new OutBuffer;
        buf.write(nativeToBigEndian(length));
        buf.write(cast(ubyte) isDir);
        buf.write(nativeToBigEndian(attributes));
        buf.write(name);
        return buf.toBytes();
    }
    int opCmp(ref const NetDirEntry e) const {
        return cmp(name, e.name);
    }
    static NetDirEntry[] splitRawData(ubyte[] data_) {
        ubyte[] data = data_;
        NetDirEntry[] output;
        while(data.length) {
            ubyte[uint.sizeof] tmp = data[0..uint.sizeof];
            data = data[uint.sizeof..$];
            auto s = bigEndianToNative!uint(tmp);
            output ~= NetDirEntry(data[0..s]);
            data = data[s..$];
        }
        return output;
    }
}

version(Posix) {
    extern(C) {
        struct winsize {
            ushort ws_row;
            ushort ws_col;
            ushort ws_xpixel;
            ushort ws_ypixel;
        };
        int ioctl (int __fd, c_ulong __request, ...);
        enum TIOCGWINSZ = 0x5413;
    }
    auto getTermSize() {
        Tuple!(ushort,"w", ushort,"h") dims;
        winsize w;
        ioctl(0, TIOCGWINSZ, &w);
        dims.w = w.ws_col;
        dims.h = w.ws_row;
        return dims;
    }
}

static void progressBar(ulong val, ulong total) {
    ushort columns = 80;
    version(Posix) {
        columns = getTermSize().w;
    }
    auto width = columns - 9;
    auto app = appender!string();
    app.reserve(columns);
    app.put('[');
    auto ratio = val / cast(double)total;
    auto size = cast(uint) (ratio * width);

    foreach(i; 0..size) {
        app.put('=');
    }
    foreach(j; size..width) {
        app.put(' ');
    }
    formattedWrite(app, "] %d%%", cast(uint) (ratio * 100));
    if(app.capacity) {
        auto padding = new char[app.capacity-columns-1];
        padding[] = ' ';
        app.put(padding);
    }

    write(strip(app.data));
    version(Posix) {
        write("\n\33[1A\33[2K");
    }
    else {
        write("\r");
        stdout.flush();
    }
}

abstract class NFT {
public:
    this() {
        commands["ls"] = &ls;
        commands["pwd"] = &pwd;
        commands["cd"] = &cd;
        commands["cpfr"] = &cpfr;
        commands["cptr"] = &cptr;
        commands["du"] = &du;
        dir = getcwd();
        status = true;
        socks = new SocketSet;
    }

    void attachControlSocket(Socket sock) {
        control = sock;
        socks.add(control);
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
        socks.add(dataSock);

        version(Windows) dataSock.blocking = true;
        try {
            dataSock.connect(remote);
        }
        catch(SocketOSException e) {
            stderr.writeln(e.msg);
        }
    }

    void sendFile(ref File file, bool progress = false) {
        if(dataSock.isAlive()) {
            ulong bytesSent;
            foreach(ubyte[] buf; file.byChunk(BUFSIZE)) {
retry:
                auto bytes = dataSock.send(buf);
                if(bytes == Socket.ERROR)
                    throw new NetworkErrorException;
                else if(bytes == 0)
                    throw new DisconnectException(dataSock);
                else if(bytes == buf.length) {
                    bytesSent += bytes;
                    if(progress) progressBar(bytesSent, file.size);
                }
                else {//retry incomplete send
                    buf = buf[bytes..$];
                    bytesSent += bytes;
                    goto retry;
                }
            }
        }
        if(progress) writeln();
    }

    void receiveFile(ref File file, ulong size, bool progress = false) {
        if(dataSock.isAlive()) {
            StopWatch timer;
            TickDuration last = TickDuration.from!"seconds"(0);
            timer.start();
            ulong bytesReceived;
            ubyte[BUFSIZE] buf;
            while(bytesReceived < size) {
                Socket.select(socks, null, null);
                if(socks.isSet(control)) {
                    Reply r = receiveMsg!Reply();
                    if(r.rt == ReplyType.ERROR) {
                        stderr.writeln(cast(string) r.reply);
                        break;
                    }
                }
                if(socks.isSet(dataSock)) {
                    auto bytes = dataSock.receive(buf);
                    if(bytes > 0) {
                        bytesReceived += bytes;
                        if(progress) {
                            if(cast(core.time.Duration)(timer.peek() - last) > dur!"msecs"(200)) {
                                progressBar(bytesReceived, size);
                                last = timer.peek();
                            }
                        }
                        file.rawWrite(buf[0..bytes]);
                    }
                    else if(bytes == 0)
                        throw new DisconnectException(dataSock);
                    else if(bytes == Socket.ERROR)
                        throw new NetworkErrorException;
                    else
                        throw new Exception("Wrong amount of data received");
                }
            }
            timer.stop();
            if(progress) {
                writeln();
                writeln("File downloaded in: ", timer.peek().msecs, " msecs");
                writefln("Average download speed: %.2f KB/s", (size/(timer.peek().to!("msecs",double)()/1000)/1024));
            }
            if(size != file.size) {
                throw new Exception("File size doesn't match");
            }
        }
        file.flush();
        file.close();
    }

    void sendMsg(Msg)(Msg msg) if(isMsgType!Msg) {
        auto bytes = control.send(cast(const(void)[]) msg);
        if(bytes == msg.length) {
            success!Msg();
            return;
        }
        else if(bytes == 0)
            throw new DisconnectException(control);
        else if(bytes == Socket.ERROR)
            throw new NetworkErrorException;
        else
            throw new Exception("Wrong amount of data sent");
    }

    Msg receiveMsg(Msg)() if(isMsgType!Msg) {
        //first 5 bytes should be size of data (4 bytes) + msg type (1 byte)
        ubyte[5] buf;
        auto bytes = control.receive(buf);

        if(bytes == buf.length) {
            static if(is(Msg == Command)) {
                if(buf[int.sizeof] != MsgType.CMD) throw new WrongMsgException(typeid(Command),typeid(Reply));
            }
            else {
                if(buf[int.sizeof] != MsgType.REPLY) throw new WrongMsgException(typeid(Reply),typeid(Command));
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
            throw new DisconnectException(control);
        }
        else if(bytes == Socket.ERROR) {
            throw new NetworkErrorException;
        }
        else
            throw new Exception("Wrong amount of data received");
    }

    auto remoteAddress() {
        return control.remoteAddress();
    }

    @property {
        string[] getCommands() {
            string[] tmp;
            foreach(k, cmd; commands) {
                tmp ~= k;
            }
            return tmp;
        }
    }

    bool status;

protected:
    Array!Command cmdBuf;
    Array!Reply replyBuf;
    alias bool delegate(string[] args ...) cmd;
    cmd[string] commands;
    Socket control;
    Socket dataSock;
    SocketSet socks;

private:
    //TODO client-side commands

    bool ls(string[] args ...) {
        auto x = replyBuf.length;
        if(args.length) {
//            foreach(arg; args) {
//                //FIXME handle argument for ls
//            }
        }
        NetDirEntry[] tmp;
        foreach(entry; filter!"!a.isSymlink"(dirEntries(dir, SpanMode.shallow))) {
            tmp ~= NetDirEntry(entry);
            tmp[$-1].name = relativePath(entry.name, dir);
        }
        replyBuf.insertBack(Reply(assumeUnique(tmp)));
        return replyBuf.length == x+1;
    }

    bool du(string[] args ...) {
        auto x = replyBuf.length;
        if(args.length) {
            if(args[0].exists && args[0].isFile) {
                replyBuf.insertBack(Reply(to!string(dirEntry(args[0]).size) ~ " bytes"));
            }
            else {
                replyBuf.insertBack(Reply(args[0] ~ ": not a file"));
            }
        }
        else {
            replyBuf.insertBack(Reply("du requires an argument.", ReplyType.ERROR));
        }
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
            if(str.exists && str.isDir) {
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

    bool cpfr(string[] args ...) {
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
                    this.sendMsg(*reply);
                    while(true) {
                        try {
                            dataSock = sock.accept();
                            version(Windows) dataSock.blocking = true;
                            break;
                        }
                        catch(SocketOSException e) {
                        }
                    }
                    sendFile(f);
                }
                catch(Exception e) {
                    stderr.writeln(e.msg);
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

    bool cptr(string[] args ...) {
        auto x = replyBuf.length;
        //TODO client uploading
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
                    capture.popFront();
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
        auto tmp = array(filter!(`a.length > 0`)(std.algorithm.splitter(input[1..$],cast(ubyte)0)));
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
    this(immutable(NetDirEntry)[] es) {
        rt = ReplyType.DIR_ENTRIES;
        foreach(e; es) {
            reply ~= cast(ubyte[]) e;
        }
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
        return cast(string[]) array(filter!(`a.length > 0`)(std.algorithm.splitter(reply,cast(ubyte)0)));
    }

    ubyte rt;
    ubyte[] reply;
}
