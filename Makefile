DMD = dmd
FLAGS = -gc

all: server client

server:
	$(DMD) $(FLAGS) server.d

client:
	$(DMD) $(FLAGS) client.d