module util;

import std.file,
std.stdio,
std.string,
std.array,
std.algorithm,
std.path,
std.exception,
std.container,
std.socket,
std.traits,
std.concurrency
;

enum MsgType : ubyte {
    CMD,
    REPLY,
    DATA,
}

enum ReplyType : ubyte {
    STRING,
    ERROR,
}

enum BUFSIZE = 8 * 1024;

template isMsgType(T) {
    enum isMsgType = __traits(compiles, cast(const(void)[]) T);
}

abstract class NFT {
public:
    this() {
        commands["ls"] = &ls;
        commands["pwd"] = &pwd;
        commands["cd"] = &cd;
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
            throw new Exception("Wrong amount of data received");
    }

    Msg receive(Msg)() if(isMsgType!Msg) {
        //first 5 bytes should be size of data (4 bytes) + msg type (1 byte)
        ubyte[5] buf;
        auto bytes = control.receive(buf);
        if(bytes == buf.length) {
            if(buf[int.sizeof] != MsgType.CMD) throw new Exception("Wrong message type");
            int msgSize = (cast(int[]) buf[0..int.sizeof])[0];
            auto buffer = new ubyte[msgSize];
            bytes = control.receive(buffer);
            if(bytes == msgSize-1)
                return Msg(buf[int.sizeof] ~ buffer);
        }
        if(bytes == 0) {
            throw new Exception("Client has disconnected");
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

private:
    bool ls(string[] args ...) {
        auto x = replyBuf.length;
        if(args.length) {
            foreach(arg; args) {
                writeln(arg);
            }
        }
        string tmp;
        foreach(string name; dirEntries(dir, SpanMode.shallow)) {
            tmp ~= relativePath(name) ~ 0;
        }
        replyBuf.insertBack(Reply(tmp[0..$-1]));
        return replyBuf.length == x+1;
    }

    bool pwd(string[] args ...) {
        auto x = replyBuf.length;
        replyBuf.insertBack(Reply(absolutePath(dir)));
        return replyBuf.length == x+1;
    }

    bool cd(string[] args ...) {
        auto x = replyBuf.length;
        if(args.length) {
            auto str = buildNormalizedPath(absolutePath(args[0], dir));
            if(str.isDir) {
                dir = str;
                replyBuf.insertBack(Reply(str));
            }
            else
                replyBuf.insertBack(Reply(absolutePath(dir)));
        }
        else
            dir = getcwd();
        return replyBuf.length == x+1;
    }

    string dir;
}

struct Command {
    this(string input) {
        auto tmp = split(strip(input));
        if(tmp.length) {
            cmd = tmp[0];
            if(tmp.length > 1) {
                args = tmp[1..$];
            }
        }
        else cmd = strip(input);
    }
    this(ubyte[] input) {
        //if taking the raw input it should at least be the right type
        enforce(input[0] == MsgType.CMD,"Not a CMD");
        auto tmp = array(filter!(a => a.length > 0)(splitter(input[1..$],cast(ubyte)0)));
        if(tmp.length) {
            cmd = cast(string) tmp[0];
            if(tmp.length > 1) {
                args = cast(string[]) tmp[1..$];
            }
        }
        else cmd = strip(cast(string)input);
    }

    @property int length() {
        return cast(int) (1 + cmd.length + 1 + reduce!("a + b.length")(0L,args) + args.length);
    }

    T opCast(T)() {
        static if(is(T == const(void)[])) {
            void[] tmp;
            //tmp.length = this.length;
            tmp ~= [length];
            tmp ~= [MsgType.CMD];
            tmp ~= cast(ubyte[])(cmd ~ 0);
            foreach(arg; args) {
                tmp ~= cast(ubyte[])(arg ~ 0);
            }
            return tmp;
        }
    }

    string cmd;
    string[] args;
    size_t seq;
}

struct Reply {
    this(ubyte[] input) {
        enforce(input[0] == MsgType.REPLY,"Not a REPLY");
        reply = input[1..$];
    }
    this(string input) {
        reply = cast(ubyte[])input;
    }
    this(string[] input) {
        foreach(str; input) {
            reply ~= cast(ubyte[]) str ~ 0;
        }
        reply = reply[0..$-1];
    }

    @property int length() {
        return cast(int)(int.sizeof + reply.length + 1);
    }

    T opCast(T)() {
        static if(is(T == const(void)[])) {
            void[] tmp;
            tmp ~= [length];
            tmp ~= [MsgType.REPLY];
            tmp ~= reply;
            return tmp;
        }
    }

    string[] splitData() {
        return cast(string[]) array(filter!(a => a.length > 0)(splitter(reply,cast(ubyte)0)));
    }

    ubyte[] reply;
    size_t seq;
}
