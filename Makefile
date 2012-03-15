DMD ?= dmd
FLAGS = -gc -inline

ifeq ($(OSTYPE), gnu-linux)
	OBJ = o
	EXE =
	RM = rm
else
	OBJ = obj
	EXE = .exe
	RM = del
endif

all: server client

server: server.$(OBJ) util.$(OBJ)
	$(DMD) $(FLAGS) $^ -of$@

client: client.$(OBJ) util.$(OBJ)
	$(DMD) $(FLAGS) $^ -of$@

%.$(OBJ): %.d
	$(DMD) $(FLAGS) -c $<

clean:
	$(RM) *.$(OBJ) client$(EXE) server$(EXE)
