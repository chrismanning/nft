import std.stdio,std.socket,std.getopt,
        std.algorithm,std.string;
import util;

ushort port = 4321;
string server = "127.0.0.1";
bool verbose;

void main(string[] args) {
    getopt(args,"server|s", &server,
                "port|p",   &port,
                "verbose|v",&verbose);

    Socket control = new TcpSocket;
    try control.connect(new InternetAddress(server,port));
    catch(SocketOSException e) {
        stderr.writeln(e.msg);
        return;
    }

    if(control.isAlive()) {
        //receive welcome message
        ubyte[1024] wbuf;
        auto bytes = control.receive(wbuf);
        if(bytes == Socket.ERROR) {
            return;
        }
        if(wbuf.length > int.sizeof) {
            auto tmp = (cast(int[])wbuf)[0];
            writeln(Command(wbuf[int.sizeof..int.sizeof+tmp]).cmd);
        }

        while(!stdin.eof()) {
            write(" > ");
            string buf;
            stdin.readln(buf);
            if(buf.length) {
                control.send(cast(const(void)[]) Command(strip(buf)));
            }
            //wait for reply
            bytes = control.receive(wbuf);
            if(bytes > int.sizeof) {
                auto size = (cast(int[])wbuf)[0];
                auto tmp = wbuf[int.sizeof..size];
                auto r = Reply(tmp);
                writeln(r.splitData());
            }
        }
    }
    writeln("bye");
    control.close();
}

class Client {
}
