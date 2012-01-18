DMD = dmd
FLAGS = -gc

all: server client

server: server.d
	$(DMD) $(FLAGS) server.d

client: client.d
	$(DMD) $(FLAGS) client.d

clean:
	rm -f *.o client server
