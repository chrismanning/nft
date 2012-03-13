DMD ?= dmd
FLAGS = -gc -inline

all: server client

server: server.o util.o
	$(DMD) $(FLAGS) $^ -of$@

client: client.o util.o
	$(DMD) $(FLAGS) $^ -of$@

%.o: %.d
	$(DMD) $(FLAGS) -c $<

clean:
	rm -f *.o client server
