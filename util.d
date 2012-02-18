module util;

class ProtocolInterpreter {

}

enum MsgType : ubyte {
    cmd,
    reply,
    data,
}

class Message {
    MsgType msg;
    this(MsgType msg) {
        this.msg = msg;
    }
}

class Command : Message {
    this(string msg) {
        super(MsgType.cmd);

    }
}
