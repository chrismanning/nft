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
std.format,
std.range
;
version(Posix) import core.stdc.config;
version(Windows) import core.sys.windows.windows;

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

enum ID = "NFTX";

class DisconnectException : Exception {
    this(Address raddr) {
        super(to!string(raddr) ~ " disconnected");
    }
    this(Socket rsock) {
        super(to!string(rsock.remoteAddress()) ~ " disconnected");
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

class FileExistsException : Exception {
    this(string msg) {
        super(msg);
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
struct Dimensions {
    ushort w;
    ushort h;
}
version(Posix) {
    extern(C) {
        struct winsize {
            ushort ws_row;
            ushort ws_col;
            ushort ws_xpixel;
            ushort ws_ypixel;
        };
        int ioctl(int __fd, c_ulong __request, ...);
        enum TIOCGWINSZ = 0x5413;
    }
    auto getTermSize() {
        Dimensions dims;
        winsize w;
        ioctl(0, TIOCGWINSZ, &w);
        dims.w = w.ws_col;
        dims.h = w.ws_row;
        return dims;
    }
}
version(Windows) {
    auto getTermSize() {
        CONSOLE_SCREEN_BUFFER_INFO bi;
        GetConsoleScreenBufferInfo(GetStdHandle(STD_OUTPUT_HANDLE), &bi);
        return cast(Dimensions) bi.dwSize;
    }
}

static void progressBar(ulong val, ulong total) {
    ushort columns = getTermSize().w;
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
    version(Windows) {
        write("\r");
        stdout.flush();
    }
}

static void lsPrettyPrint(T)(T entries_) if(is(T == NetDirEntry[]) || is(T == DirIterator)) {
    static if(is(T == DirIterator)) {
        NetDirEntry[] entries;
        foreach(DirEntry e; entries_) {
            entries ~= NetDirEntry(e);
        }
    }
    else {
        auto entries = entries_;
    }
    auto columns = getTermSize().w;
    auto app = appender!string();
    //strip off anything other than the file/dir name
    entries = array(map!(delegate (NetDirEntry e) {e.name = baseName(e.name); return e;})(entries));
    //get maximum length of entries
    auto width = reduce!((a,b) => max(a,cast(int)b.name.length))(0, entries.sort) + 1;
    if(width > columns / 2)
        width = columns;
    uint counter;
    foreach(e; entries) {
        string pad;
        counter++;
        if(!(counter % (columns / width))) {
            version(Windows){}
            else pad = "\n";
        }
        string name;
        ubyte n;
        version(Posix) {
            if(e.isDir) {
                name = "\33[01;34m" ~ e.name;
            }
            else {
                if(e.attributes & octal!100) {
                    name = "\33[01;32m" ~ e.name;
                }
                else {
                    name = "\33[00;37m" ~ e.name;
                }
            }
            n = 8;
        }
        else name = e.name;
        formattedWrite(app,"%-0*s%s", width + n, name, pad);
    }
    writeln(strip(app.data));
    version(Posix) write("\33[00;37m");
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
        commands["rm"] = &rm;
        commands["mkdir"] = &mkdir_;

        localCommands["locls"] = &locls;
        localCommands["locpwd"] = &locpwd;
        localCommands["locdu"] = &locdu;
        localCommands["loccd"] = &loccd;
        localCommands["locrm"] = &locrm;
        localCommands["locmkdir"] = &locmkdir;

        prevDir = dir = getcwd();
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

        dataSock.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, dur!"seconds"(15));

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
            StopWatch timer;
            TickDuration last = TickDuration.from!"seconds"(0);
            timer.start();
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
                    if(progress) {
                        if(cast(core.time.Duration)(timer.peek() - last) > dur!"msecs"(200)) {
                            progressBar(bytesSent, file.size);
                            last = timer.peek();
                        }
                    }
                }
                else {//retry incomplete send
                    buf = buf[bytes..$];
                    bytesSent += bytes;
                    goto retry;
                }
            }
            timer.stop();
            if(progress) {
                version(Windows) writeln();
                writeln("File uploaded in: ", timer.peek().msecs, " msecs");
                writefln("Average uploaded speed: %.2f KB/s", (file.size/(timer.peek().to!("msecs",double)()/1000)/1024));
            }
        }
    }

    void receiveFile(ref File file, ulong size, bool progress = false) {
        if(dataSock.isAlive()) {
            StopWatch timer;
            TickDuration last = TickDuration.from!"seconds"(0);
            timer.start();
            ulong bytesReceived;
            ubyte[BUFSIZE] buf;
            socks.reset();
            while(bytesReceived < size) {
                socks.add(control);
                socks.add(dataSock);
                Socket.select(socks, null, null, dur!"seconds"(5));
                if(socks.isSet(control)) {
                    Reply r = receiveMsg!Reply();
                    if(r.rt == ReplyType.ERROR) {
                        stderr.writeln(cast(string) r.reply);
                        break;
                    }
                    replyBuf.insertBack(r);
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
                socks.reset();
            }
            timer.stop();
            if(progress) {
                version(Windows) writeln();
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
        auto bytes = control.send(cast(ubyte[]) ID ~ cast(const(void)[]) msg);
        if(bytes == msg.length + ID.length) {
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
        static if(is(Msg == Reply)) {
            if(replyBuf.length) {
                return replyBuf.removeAny();
            }
        }
        //first 9 bytes should be ID (4 bytes) + size of data (4 bytes) + msg type (1 byte)
        ubyte[9] buf_;
        auto bytes = control.receive(buf_);
        enforceEx!Exception(buf_[].startsWith(ID), "Not an NFT message");
        auto buf = buf_[4..$];

        if(bytes == buf.length + ID.length) {
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
    alias bool delegate(string arg) cmd;
    alias void delegate(string arg) localCmd;
    cmd[string] commands;
    localCmd[string] localCommands;
    Socket control;
    Socket dataSock;
    SocketSet socks;

private:
    //client-side commands
    void locls(string arg) {
        string dir = ".";
        if(arg.length) {
            dir = strip(arg);
            if(!dir.exists) {
                stderr.writeln(dir, ": no such file or directory.");
                return;
            }
        }
        lsPrettyPrint(dirEntries(dir, SpanMode.shallow));
    }

    void loccd(string arg) {
        if(arg.length) {
            if(arg == "-") {
                chdir(prevDir);
            }
            else if(arg.exists && arg.isDir) {
                prevDir = getcwd();
                chdir(absolutePath(arg));
            }
            else {
                stderr.writeln(arg, ": no such directory.");
            }
        }
        else {
            chdir(dir);
        }
    }

    void locpwd(string arg) {
        writeln(getcwd());
    }

    void locdu(string arg) {
        if(arg.length) {
            if(arg.exists && arg.isFile) {
                writeln(dirEntry(arg).size, " bytes");
                return;
            }
            stderr.writeln(arg, ": not a file");
            return;
        }
        stderr.writeln("locdu requires an argument.");
    }

    void locrm(string arg) {
        if(arg.length) {
            try {
                if(arg.isDir)
                    arg.rmdir();
                else if(arg.isFile)
                    arg.remove();
            }
            catch(FileException e) {
                stderr.writeln(e.msg);
            }
        }
    }

    void locmkdir(string arg) {
        if(arg.length) {
            try {
                mkdir(arg);
            }
            catch(FileException e) {
                stderr.writeln(e.msg);
            }
        }
    }

    //server-side commands
    bool ls(string arg) {
        auto x = replyBuf.length;
        string dir_ = dir;
        if(arg.length && arg.exists && arg.isDir) {
            dir_ = arg;
        }
        NetDirEntry[] tmp;
        foreach(entry; filter!(a => !a.isSymlink)(dirEntries(dir_, SpanMode.shallow))) {
            tmp ~= NetDirEntry(entry);
            tmp[$-1].name = baseName(entry.name);
        }
        if(tmp.length) {
            replyBuf.insertBack(Reply(assumeUnique(tmp)));
        }
        else {
            replyBuf.insertBack(Reply("Nothing here"));
        }
        return replyBuf.length == x+1;
    }

    bool du(string arg) {
        auto x = replyBuf.length;
        if(arg.length) {
            auto filename = absolutePath(strip(arg), dir);
            if(filename.exists && filename.isFile) {
                replyBuf.insertBack(Reply(to!string(dirEntry(filename).size) ~ " bytes"));
            }
            else {
                replyBuf.insertBack(Reply(filename ~ ": not a file."));
            }
        }
        else {
            replyBuf.insertBack(Reply("du requires an argument.", ReplyType.ERROR));
        }
        return replyBuf.length == x+1;
    }

    bool pwd(string arg) {
        auto x = replyBuf.length;
        replyBuf.insertBack(Reply(absolutePath(dir), ReplyType.STRING));
        return replyBuf.length == x+1;
    }

    bool cd(string arg) {
        auto x = replyBuf.length;
        if(arg.length) {
            auto str = buildNormalizedPath(absolutePath(arg, dir));
            if(str.exists && str.isDir) {
                dir = str;
                replyBuf.insertBack(Reply(str, ReplyType.STRING));
            }
            else
                replyBuf.insertBack(Reply(arg ~ ": no such directory.", ReplyType.ERROR));
        }
        else {
            dir = getcwd();
            replyBuf.insertBack(Reply(dir, ReplyType.STRING));
        }
        return replyBuf.length == x+1;
    }

    bool rm(string arg) {
        auto x = replyBuf.length;
        if(arg.length) {
            try {
                if(arg.isDir)
                    arg.rmdir();
                else if(arg.isFile)
                    arg.remove();
                replyBuf.insertBack(Reply("Removed " ~ arg, ReplyType.STRING));
            }
            catch(FileException e) {
                replyBuf.insertBack(Reply(e.msg, ReplyType.ERROR));
            }
        }
        return replyBuf.length == x+1;
    }

    bool mkdir_(string arg) {
        auto x = replyBuf.length;
        if(arg.length) {
            try {
                mkdir(arg);
                replyBuf.insertBack(Reply("Created " ~ arg, ReplyType.STRING));
            }
            catch(FileException e) {
                stderr.writeln(e.msg);
                replyBuf.insertBack(Reply(e.msg, ReplyType.ERROR));
            }
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

    //server to client transfer
    bool cpfr(string arg) {
        auto x = replyBuf.length;
        Reply * reply;
        if(arg.length) {
            auto filename = absolutePath(arg, dir);
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
                            dataSock.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, dur!"seconds"(15));
                            version(Windows) dataSock.blocking = true;
                            break;
                        }
                        catch(SocketOSException e) {
                        }
                    }
                    sendFile(f);
                    reply = new Reply("File successfully sent from server");
                }
                catch(Exception e) {
                    stderr.writeln(e.msg);
                    reply = new Reply(e.msg, ReplyType.ERROR);
                }
                finally {
                    if(reply) {
                        replyBuf.insertBack(*reply);
                    }
                    dataSock.close();
                }
            }
            else {
                replyBuf.insertBack(Reply(arg ~ ": No such file", ReplyType.ERROR));
            }
        }
        else {
            replyBuf.insertBack(Reply("Need an argument", ReplyType.ERROR));
        }
        return replyBuf.length == x+1;
    }

    //client to server transfer
    bool cptr(string arg) {
        auto x = replyBuf.length;
        Reply * reply;
        if(arg.length) {
            auto filename = baseName(arg);
            try {
                auto sock = this.openDataConnection();
                auto p = sock.localAddress().toPortString();
                auto port = parse!ushort(p);
                auto rb = nativeToBigEndian(port) ~ nativeToBigEndian!ulong(0);
                reply = new Reply(rb, ReplyType.DATA_SETUP);
                sendMsg(*reply);
                while(true) {
                    try {
                        dataSock = sock.accept();
                        dataSock.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, dur!"seconds"(15));
                        version(Windows) dataSock.blocking = true;
                        break;
                    }
                    catch(SocketOSException e) {
                    }
                }
                auto rtmp = receiveMsg!Reply();
                ubyte[ulong.sizeof] tmp = rtmp.reply;
                auto fileSize = bigEndianToNative!ulong(tmp);
                if(filename.exists && getSize(filename) == fileSize) {
                    throw new FileExistsException("File transfer not needed");
                }
                auto f = File(filename,"wb");
                receiveFile(f, fileSize);
                reply = new Reply("File successfully received at server");
            }
            catch(Exception e) {
                stderr.writeln(e.msg);
                reply = new Reply(e.msg, ReplyType.ERROR);
            }
            finally {
                if(reply) {
                    replyBuf.insertBack(*reply);
                }
                dataSock.close();
            }
        }
        else {
            replyBuf.insertBack(Reply("Need an argument", ReplyType.ERROR));
        }
        return replyBuf.length == x+1;
    }

    string dir;
    string prevDir;
}

struct Command {
    this(string input) {
        auto idx = countUntil(input, ' ');
        if(idx > 0) {
            cmd = input[0..idx];
            arg = strip(input[idx..$]);
        }
        else {
            cmd = strip(input);
        }
    }
    this(ubyte[] input) {
        //if taking the raw input it should at least be the right type
        enforce(input[0] == MsgType.CMD,"Not a CMD");
        auto tmp = array(filter!(`a.length > 0`)(std.algorithm.splitter(input[1..$],cast(ubyte)0)));
        if(tmp.length) {
            cmd = cast(string) tmp[0];
            if(tmp.length > 1) {
                arg = cast(string) tmp[1];
            }
        }
        else cmd = strip(cast(string)input);
    }

    @property uint length() {
        return cast(uint) (uint.sizeof + 1 + cmd.length + 1 + arg.length);
    }

    const(void)[] opCast() {
        auto buf = new OutBuffer;
        buf.reserve(length);

        buf.write(nativeToBigEndian(length).dup);
        buf.write(cast(ubyte) MsgType.CMD);
        buf.write(cmd);
        buf.write(new ubyte[1]);
        buf.write(arg);
        return buf.toBytes();
    }

    string cmd;
    string arg;
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
