module util;

import std.file,std.stdio,std.string,std.array,std.algorithm,
        std.exception;

alias ubyte[] function(string[] args = []) cmd;
cmd[string] commands;

static this() {
    commands["ls"] = &ls;
}

enum MsgType : ubyte {
    CMD,
    REPLY,
    DATA,
}

struct Message {
    MsgType msg;
    this(MsgType msg) {
        this.msg = msg;
    }
}

ubyte[] ls(string[] args) {
    string dir = ".";
    if(args.length && args[0].length) dir = args[0];

    ubyte[] tmp;
    tmp ~= MsgType.REPLY;
    foreach(string name; dirEntries(dir, SpanMode.shallow)) {
        tmp ~= cast(ubyte[]) name ~ cast(ubyte) 0;
    }

    return tmp;
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
}

struct Reply {
    this(ubyte[] input) {
        enforce(input[0] == MsgType.REPLY,"Not a REPLY");
        reply = input[1..$];
    }
    this(string input) {
        reply = cast(ubyte[])input;
    }
    @property int length() {
        return cast(int)(reply.length + int.sizeof);
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
}
