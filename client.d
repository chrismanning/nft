import std.stdio,std.socket,std.getopt,
        std.algorithm,std.string;
import util;

ushort port = 4321;
ushort dataPort = 4320;
string server = "127.0.0.1";
bool verbose;
uint retries = 3;

void main(string[] args) {
    getopt(args,"server|s", &server,
                "port|p", &port,
                "data-port|dp", &dataPort,
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

        string buf;
        while(!stdin.eof()) {
            write(" > ");
            buf = strip(stdin.readln());
            if(buf.length) {
                if(buf == "break") break;
                if(verbose) writeln("Sending command to server...");
                control.send(cast(const(void)[]) Command(buf));
                //wait for reply
                if(verbose) writeln("Waiting for reply from server...");
                bytes = control.receive(wbuf);
                if(bytes > int.sizeof) {
                    auto size = (cast(int[])wbuf)[0];
                    auto tmp = wbuf[int.sizeof..size];
                    auto r = Reply(tmp);
                    writeln(r.splitData());
                }
                buf.length = 0;
            }
        }
        writeln("exit");
    }
    writeln("bye");
    control.close();
}

class Client : NFT {
}
