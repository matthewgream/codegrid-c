
NAME=codegrid

CC=gcc
CFLAGS=\
    -std=c23 \
    -Wfloat-conversion -Werror=float-conversion \
    -Wall -Wextra -Werror -Wpedantic \
    -Wstrict-prototypes -Wold-style-definition \
    -Wcast-align -Wcast-qual -Wconversion \
    -Wfloat-equal -Wformat=2 -Wformat-security \
    -Winit-self -Wjump-misses-init \
    -Wlogical-op -Wmissing-include-dirs \
    -Wnested-externs -Wpointer-arith \
    -Wredundant-decls -Wshadow \
    -Wstrict-overflow=2 -Wswitch-default \
    -Wunreachable-code -Wunused \
    -Wwrite-strings \
    -Wdouble-promotion \
    -Wnull-dereference \
    -Wstack-usage=2048 \
    -Wduplicated-cond \
    -Wduplicated-branches \
    -Wrestrict \
    -Wstringop-overflow \
    -Wundef \
    -Wvla \
    -Wno-overlength-strings \
    -O3
COPTS=-DZOOM9_ONLY
LDFLAGS=-lm
INCLUDES=
TARGET=$(NAME)
SOURCES=$(NAME).c

all: $(TARGET)

$(TARGET): $(SOURCES)
	$(CC) $(CFLAGS) $(COPTS) $(INCLUDES) $(SOURCES) -o $(TARGET) $(LDFLAGS)

clean:
	rm -rf $(TARGET)

tiles:
	./gentiles.sh tiles codegrid_tiles.h

test:
	./$(TARGET)

testjs:
	node $(TARGET).js

unpack:
	bzip2 -d < $(TARGET)_tiles.tar.bz2 | tar xvf -

.PHONY: all clean tiles
