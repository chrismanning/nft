DMD ?= dmd
FLAGS = -gc -inline -O -release

ifeq ($(OS), Windows_NT)
	OBJ = obj
	EXE = .exe
	RM = del
else
	OBJ = o
	EXE =
	RM = rm -f
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
