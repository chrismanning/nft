DMD = dmd
FLAGS = -gc -inline

all: server client

server: server.o util.o
	$(DMD) $(FLAGS) $^

client: client.o util.o
	$(DMD) $(FLAGS) $^

%.o: %.d
	$(DMD) $(FLAGS) -c $<

clean:
	rm -f *.o client server
